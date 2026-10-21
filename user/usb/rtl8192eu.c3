module user;

import std::nolibc::mem;
import std::nolibc::fmt;

// Realtek RTL8192EU USB Wi-Fi (TP-Link TL-WN823N v2/v3, 2357:0109 and
// friends) — a class driver inside usbd, like msc.c3.
//
// Ported from Linux drivers/net/wireless/realtek/rtl8xxxu (core.c +
// 8192e.c, GPL-2.0-only; the register constants and init tables are
// generated from it into rtl8192eu_regs.c3). The licensing of this port
// inside an MIT tree is an open question the project owner parked; keep
// it in these two files.
//
// What it does today: probe, read the efuse (MAC, TX power), download
// the firmware (/lib/firmware/rtl8192eu_nic.bin), the full MAC/BB/RF
// bring-up, channel switching, and a passive scan that collects beacons
// and probe responses. Association, the data path and WPA2 come next
// (W4/W5 in the plan). Not done: IQ calibration (RX still works without
// it, less sensitive), crystal-cap trim, rate adaptation, power saving.
//
// Registers are reached with vendor control transfers (bRequest 0x05,
// wValue = address). Frames arrive on the one bulk IN endpoint, polled
// one non-blocking attempt at a time from usbd's fast loop
// (rtl_poll), each transfer a 24-byte RX descriptor + PHY status + the
// 802.11 frame.

const uint RTL_USB_REQ = 0x05;
const uint RTL_EFUSE_LEN = 512;
const uint RTL_FW_HDR = 32;
const uint RTL_FW_MAX = 40960;
const uint RTL_RX_BUF = 4096;    // one page: the usbd DMA region
const uint RTL_TX_DESC = 40;
const int  RTL_BSS_MAX = 24;

struct Rtl_bss
{
	bool used;
	char[6] bssid;
	char[33] ssid;
	uint channel;
	int rssi;
	bool privacy;
	bool rsn;
	uint rsn_why;     // 0 = a WPA2-PSK/CCMP BSS we can join (rtl_rsn_check)
	ulong last_seen;
}

bool g_rtl_present;
uint g_rtl_dev;
uint g_rtl_mps0;
uint g_rtl_ep_in;
uint g_rtl_ep_in_mps;
uint g_rtl_pid_in;
uint[3] g_rtl_ep_out;
uint[3] g_rtl_pid_out;
uint g_rtl_nr_out;
uint g_rtl_tx_paths;
bool g_rtl_up;
uint g_rtl_channel;
char[6] g_rtl_mac;
char[RTL_EFUSE_LEN] g_rtl_efuse;
char[RTL_FW_MAX] g_rtl_fw;
uint g_rtl_fw_len;
char[RTL_RX_BUF] g_rtl_rx;
Rtl_bss[RTL_BSS_MAX] g_rtl_bss;
bool g_rtl_scanning;
uint g_rtl_scan_ch;
ulong g_rtl_scan_next;
ulong g_rtl_rx_frames;
ulong g_rtl_rx_errors;
bool g_rtl_autojoin_tried;
ulong g_rtl_kicked;      // g_sta_rx_data at the last doorbell
bool g_rtl_cck_agc_hi;   // REG_FPGA0_XA_HSSI_PARM2's CCK high-power bit: which LNA gain table

// --- register access ---------------------------------------------------

fn void rtl_udelay(ulong us)
{
	ulong end = rdtime() + usb_us_to_ticks(us);
	while (rdtime() < end) { }
}

fn void rtl_mdelay(ulong ms)
{
	ulong end = rdtime() + usb_us_to_ticks(ms * 1000);
	while (rdtime() < end) { yield(); }
}

fn uint rtl_read(uint addr, uint len)
{
	char[8] setup;
	setup[0] = (char)0xC0;
	setup[1] = (char)RTL_USB_REQ;
	setup[2] = (char)addr; setup[3] = (char)(addr >> 8);
	setup[4] = 0; setup[5] = 0;
	setup[6] = (char)len; setup[7] = 0;
	char[4] b;
	b[0] = 0; b[1] = 0; b[2] = 0; b[3] = 0;
	if (!usb_control_transfer(g_rtl_dev, g_rtl_mps0, &setup[0], &b[0], len, true)) { return 0xFFFFFFFF; }
	return (uint)b[0] | ((uint)b[1] << 8) | ((uint)b[2] << 16) | ((uint)b[3] << 24);
}

fn bool rtl_write(uint addr, uint val, uint len)
{
	char[8] setup;
	setup[0] = (char)0x40;
	setup[1] = (char)RTL_USB_REQ;
	setup[2] = (char)addr; setup[3] = (char)(addr >> 8);
	setup[4] = 0; setup[5] = 0;
	setup[6] = (char)len; setup[7] = 0;
	char[4] b;
	b[0] = (char)val; b[1] = (char)(val >> 8); b[2] = (char)(val >> 16); b[3] = (char)(val >> 24);
	return usb_control_transfer(g_rtl_dev, g_rtl_mps0, &setup[0], &b[0], len, false);
}

fn uint rtl_r8(uint a)  { return rtl_read(a, 1) & 0xFF; }
fn uint rtl_r16(uint a) { return rtl_read(a, 2) & 0xFFFF; }
fn uint rtl_r32(uint a) { return rtl_read(a, 4); }
fn void rtl_w8(uint a, uint v)  { rtl_write(a, v & 0xFF, 1); }
fn void rtl_w16(uint a, uint v) { rtl_write(a, v & 0xFFFF, 2); }
fn void rtl_w32(uint a, uint v) { rtl_write(a, v, 4); }

fn bool rtl_writeN(uint addr, char* buf, uint len)
{
	uint done = 0;
	while (done < len)
	{
		uint n = len - done < 128 ? len - done : 128;
		char[8] setup;
		uint a = addr + done;
		setup[0] = (char)0x40;
		setup[1] = (char)RTL_USB_REQ;
		setup[2] = (char)a; setup[3] = (char)(a >> 8);
		setup[4] = 0; setup[5] = 0;
		setup[6] = (char)n; setup[7] = 0;
		if (!usb_control_transfer(g_rtl_dev, g_rtl_mps0, &setup[0], buf + done, n, false)) { return false; }
		done += n;
	}
	return true;
}

// --- RF registers (via the baseband's 3-wire interface) ----------------

fn uint rtl_rf_hssi2(uint path) { return path == 0 ? RTL_REG_FPGA0_XA_HSSI_PARM2 : RTL_REG_FPGA0_XB_HSSI_PARM2; }
fn uint rtl_rf_hssi1(uint path) { return path == 0 ? RTL_REG_FPGA0_XA_HSSI_PARM1 : RTL_REG_FPGA0_XB_HSSI_PARM1; }
fn uint rtl_rf_lssi(uint path)  { return path == 0 ? RTL_REG_FPGA0_XA_LSSI_PARM : RTL_REG_FPGA0_XB_LSSI_PARM; }
fn uint rtl_rf_hspird(uint path){ return path == 0 ? RTL_REG_HSPI_XA_READBACK : RTL_REG_HSPI_XB_READBACK; }
fn uint rtl_rf_lssird(uint path){ return path == 0 ? RTL_REG_FPGA0_XA_LSSI_READBACK : RTL_REG_FPGA0_XB_LSSI_READBACK; }

fn uint rtl_rf_read(uint path, uint reg)
{
	uint hssia = rtl_r32(RTL_REG_FPGA0_XA_HSSI_PARM2);
	uint v = path != 0 ? rtl_r32(rtl_rf_hssi2(path)) : hssia;
	v &= ~RTL_FPGA0_HSSI_PARM2_ADDR_MASK;
	v |= reg << RTL_FPGA0_HSSI_PARM2_ADDR_SHIFT;
	v |= RTL_FPGA0_HSSI_PARM2_EDGE_READ;
	hssia &= ~RTL_FPGA0_HSSI_PARM2_EDGE_READ;
	rtl_w32(RTL_REG_FPGA0_XA_HSSI_PARM2, hssia);
	rtl_udelay(10);
	rtl_w32(rtl_rf_hssi2(path), v);
	rtl_udelay(100);
	hssia |= RTL_FPGA0_HSSI_PARM2_EDGE_READ;
	rtl_w32(RTL_REG_FPGA0_XA_HSSI_PARM2, hssia);
	rtl_udelay(10);
	uint r;
	if (rtl_r32(rtl_rf_hssi1(path)) & RTL_FPGA0_HSSI_PARM1_PI) { r = rtl_r32(rtl_rf_hspird(path)); }
	else { r = rtl_r32(rtl_rf_lssird(path)); }
	return r & 0xFFFFF;
}

fn void rtl_rf_write(uint path, uint reg, uint data)
{
	data &= RTL_FPGA0_LSSI_PARM_DATA_MASK;
	uint dataaddr = (reg << RTL_FPGA0_LSSI_PARM_ADDR_SHIFT) | data;
	uint ps = rtl_r32(RTL_REG_FPGA0_POWER_SAVE);
	rtl_w32(RTL_REG_FPGA0_POWER_SAVE, ps & ~(uint)0x20000);
	rtl_w32(rtl_rf_lssi(path), dataaddr);
	rtl_udelay(1);
	ps = rtl_r32(RTL_REG_FPGA0_POWER_SAVE);
	rtl_w32(RTL_REG_FPGA0_POWER_SAVE, ps | 0x20000);
}

// --- efuse -------------------------------------------------------------

fn bool rtl_efuse8(uint off, char* out)
{
	rtl_w8(RTL_REG_EFUSE_CTRL + 1, off & 0xFF);
	uint v8 = rtl_r8(RTL_REG_EFUSE_CTRL + 2) & 0xFC;
	rtl_w8(RTL_REG_EFUSE_CTRL + 2, v8 | ((off >> 8) & 3));
	v8 = rtl_r8(RTL_REG_EFUSE_CTRL + 3);
	rtl_w8(RTL_REG_EFUSE_CTRL + 3, v8 & 0x7F);
	for (int i = 0; i < 500; i++)
	{
		if (rtl_r32(RTL_REG_EFUSE_CTRL) & 0x80000000)
		{
			rtl_udelay(50);
			*out = (char)(rtl_r32(RTL_REG_EFUSE_CTRL) & 0xFF);
			return true;
		}
	}
	return false;
}

fn bool rtl_read_efuse()
{
	rtl_w8(RTL_REG_EFUSE_ACCESS, RTL_EFUSE_ACCESS_ENABLE);
	uint v16 = rtl_r16(RTL_REG_SYS_ISO_CTRL);
	if ((v16 & RTL_SYS_ISO_PWC_EV12V) == 0) { rtl_w16(RTL_REG_SYS_ISO_CTRL, v16 | RTL_SYS_ISO_PWC_EV12V); }
	v16 = rtl_r16(RTL_REG_SYS_FUNC);
	if ((v16 & RTL_SYS_FUNC_ELDR) == 0) { rtl_w16(RTL_REG_SYS_FUNC, v16 | RTL_SYS_FUNC_ELDR); }
	v16 = rtl_r16(RTL_REG_SYS_CLKR);
	if ((v16 & RTL_SYS_CLK_LOADER_ENABLE) == 0 || (v16 & RTL_SYS_CLK_ANA8M) == 0)
	{
		rtl_w16(RTL_REG_SYS_CLKR, v16 | RTL_SYS_CLK_LOADER_ENABLE | RTL_SYS_CLK_ANA8M);
	}
	for (uint i = 0; i < RTL_EFUSE_LEN; i++) { g_rtl_efuse[i] = (char)0xFF; }
	uint addr = 0;
	bool ok = true;
	while (addr < 512)
	{
		char hdr;
		if (!rtl_efuse8(addr, &hdr)) { ok = false; break; }
		addr++;
		if ((uint)hdr == 0xFF) { break; }
		uint offset;
		uint mask;
		if (((uint)hdr & 0x1F) == 0x0F)
		{
			char ext;
			if (!rtl_efuse8(addr, &ext)) { ok = false; break; }
			addr++;
			if (((uint)ext & 0x0F) == 0x0F) { continue; }
			offset = (((uint)hdr & 0xE0) >> 5) | (((uint)ext & 0xF0) >> 1);
			mask = (uint)ext & 0x0F;
		}
		else
		{
			offset = ((uint)hdr >> 4) & 0x0F;
			mask = (uint)hdr & 0x0F;
		}
		uint map = offset * 8;
		for (uint w = 0; w < 4; w++)
		{
			if (mask & (1u << w)) { map += 2; continue; }
			char lo;
			char hi;
			if (!rtl_efuse8(addr, &lo)) { ok = false; break; }
			addr++;
			if (!rtl_efuse8(addr, &hi)) { ok = false; break; }
			addr++;
			if (map + 1 >= RTL_EFUSE_LEN) { ok = false; break; }
			g_rtl_efuse[map] = lo;
			g_rtl_efuse[map + 1] = hi;
			map += 2;
		}
		if (!ok) { break; }
	}
	rtl_w8(RTL_REG_EFUSE_ACCESS, RTL_EFUSE_ACCESS_DISABLE);
	if (!ok) { return false; }
	uint id = (uint)g_rtl_efuse[0] | ((uint)g_rtl_efuse[1] << 8);
	if (id != 0x8129) { return false; }
	for (int i = 0; i < 6; i++) { g_rtl_mac[i] = g_rtl_efuse[0xD7 + i]; }
	return true;
}

// --- firmware ------------------------------------------------------------

fn bool rtl_load_firmware()
{
	uint off = 0;
	for (;;)
	{
		int n = fs_read_at("/lib/firmware/rtl8192eu_nic.bin", &g_rtl_fw[off], (int)(RTL_FW_MAX - off > 4096 ? 4096 : RTL_FW_MAX - off), off);
		if (n < 0) { return false; }
		if (n == 0) { break; }
		off += (uint)n;
		if (off >= RTL_FW_MAX) { return false; }
	}
	g_rtl_fw_len = off;
	uint sig = (uint)g_rtl_fw[0] | ((uint)g_rtl_fw[1] << 8);
	return off > RTL_FW_HDR && (sig & 0xFFF0) == 0x92E0;
}

fn void rtl_reset_8051()
{
	uint v8 = rtl_r8(RTL_REG_RSV_CTRL + 1);
	rtl_w8(RTL_REG_RSV_CTRL + 1, v8 & ~1u);
	uint sf = rtl_r16(RTL_REG_SYS_FUNC) & ~RTL_SYS_FUNC_CPU_ENABLE;
	rtl_w16(RTL_REG_SYS_FUNC, sf);
	v8 = rtl_r8(RTL_REG_RSV_CTRL + 1);
	rtl_w8(RTL_REG_RSV_CTRL + 1, v8 | 1);
	rtl_w16(RTL_REG_SYS_FUNC, sf | RTL_SYS_FUNC_CPU_ENABLE);
}

fn bool rtl_download_firmware()
{
	uint v8 = rtl_r8(RTL_REG_SYS_FUNC + 1);
	rtl_w8(RTL_REG_SYS_FUNC + 1, v8 | 4);
	rtl_w16(RTL_REG_SYS_FUNC, rtl_r16(RTL_REG_SYS_FUNC) | RTL_SYS_FUNC_CPU_ENABLE);
	if (rtl_r8(RTL_REG_MCU_FW_DL) & RTL_MCU_FW_RAM_SEL)
	{
		rtl_w8(RTL_REG_MCU_FW_DL, 0);
		rtl_reset_8051();
	}
	rtl_w8(RTL_REG_MCU_FW_DL, rtl_r8(RTL_REG_MCU_FW_DL) | RTL_MCU_FW_DL_ENABLE);
	rtl_w32(RTL_REG_MCU_FW_DL, rtl_r32(RTL_REG_MCU_FW_DL) & ~(1u << 19));
	rtl_w8(RTL_REG_MCU_FW_DL, rtl_r8(RTL_REG_MCU_FW_DL) | RTL_MCU_FW_DL_CSUM_REPORT);

	char* fw = &g_rtl_fw[RTL_FW_HDR];
	uint size = g_rtl_fw_len - RTL_FW_HDR;
	bool ok = true;
	for (uint page = 0; page * 4096 < size; page++)
	{
		uint n = size - page * 4096 < 4096 ? size - page * 4096 : 4096;
		rtl_w8(RTL_REG_MCU_FW_DL + 2, (rtl_r8(RTL_REG_MCU_FW_DL + 2) & 0xF8) | page);
		if (!rtl_writeN(RTL_REG_FW_START_ADDRESS, fw + page * 4096, n)) { ok = false; break; }
	}
	rtl_w16(RTL_REG_MCU_FW_DL, rtl_r16(RTL_REG_MCU_FW_DL) & ~RTL_MCU_FW_DL_ENABLE);
	return ok;
}

fn bool rtl_start_firmware()
{
	bool csum = false;
	for (int i = 0; i < 1000; i++)
	{
		if (rtl_r32(RTL_REG_MCU_FW_DL) & RTL_MCU_FW_DL_CSUM_REPORT) { csum = true; break; }
	}
	if (!csum) { print("wifi: firmware checksum never reported\n"); return false; }
	uint v = rtl_r32(RTL_REG_MCU_FW_DL);
	v |= RTL_MCU_FW_DL_READY;
	v &= ~RTL_MCU_WINT_INIT_READY;
	rtl_w32(RTL_REG_MCU_FW_DL, v);
	rtl_reset_8051();
	for (int i = 0; i < 1000; i++)
	{
		if (rtl_r32(RTL_REG_MCU_FW_DL) & RTL_MCU_WINT_INIT_READY) { return true; }
		rtl_udelay(100);
	}
	print("wifi: firmware didn't start\n");
	return false;
}

// --- power-on and the queue / page setup (8192E) --------------------------

fn bool rtl_power_on()
{
	if (rtl_r32(RTL_REG_SYS_CFG) & RTL_SYS_CFG_SPS_LDO_SEL)
	{
		rtl_w8(RTL_REG_LDO_SW_CTRL, 0xC3);
	}
	else
	{
		uint v = rtl_r32(RTL_REG_8192E_LDOV12_CTRL);
		rtl_w32(RTL_REG_8192E_LDOV12_CTRL, (v & 0xFF0FFFFF) | 0x00500000);
		rtl_w8(RTL_REG_LDO_SW_CTRL, 0x83);
	}
	// crystal / AFE adjust: 40 MHz source, PLL KVCO selection
	rtl_w8(RTL_REG_AFE_PLL_CTRL, rtl_r8(RTL_REG_AFE_PLL_CTRL) & 0xFB);
	rtl_w32(RTL_REG_AFE_CTRL4, rtl_r32(RTL_REG_AFE_CTRL4) & 0xFFFFFC7F);
	rtl_w8(RTL_REG_AFE_PLL_CTRL, rtl_r8(RTL_REG_AFE_PLL_CTRL) & 0xBF);
	rtl_w32(RTL_REG_AFE_CTRL4, rtl_r32(RTL_REG_AFE_CTRL4) & 0xFFDFFFFF);
	// disabled -> emu
	rtl_w8(RTL_REG_APS_FSMCO + 1, rtl_r8(RTL_REG_APS_FSMCO + 1) & ~(0x18u));
	// emu -> active
	rtl_w8(RTL_REG_APS_FSMCO + 1, rtl_r8(RTL_REG_APS_FSMCO + 1) & ~0x80u);
	rtl_w8(RTL_REG_APS_FSMCO + 1, rtl_r8(RTL_REG_APS_FSMCO + 1) & ~0x04u);
	rtl_w8(RTL_REG_APS_FSMCO + 1, rtl_r8(RTL_REG_APS_FSMCO + 1) & ~(0x18u));
	bool ready = false;
	for (int i = 0; i < 500; i++)
	{
		if (rtl_r32(RTL_REG_APS_FSMCO) & (1u << 17)) { ready = true; break; }
		rtl_udelay(10);
	}
	if (!ready) { print("wifi: power ready never came\n"); return false; }
	rtl_w8(RTL_REG_APS_FSMCO + 2, rtl_r8(RTL_REG_APS_FSMCO + 2) | 1);
	rtl_w32(RTL_REG_APS_FSMCO, rtl_r32(RTL_REG_APS_FSMCO) | RTL_APS_FSMCO_MAC_ENABLE);
	ready = false;
	for (int i = 0; i < 500; i++)
	{
		if ((rtl_r32(RTL_REG_APS_FSMCO) & RTL_APS_FSMCO_MAC_ENABLE) == 0) { ready = true; break; }
		rtl_udelay(10);
	}
	if (!ready) { print("wifi: MAC enable never completed\n"); return false; }
	rtl_w16(RTL_REG_CR, 0);
	uint cr = rtl_r16(RTL_REG_CR);
	cr |= RTL_CR_HCI_TXDMA_ENABLE | RTL_CR_HCI_RXDMA_ENABLE | RTL_CR_TXDMA_ENABLE | RTL_CR_RXDMA_ENABLE
		| RTL_CR_PROTOCOL_ENABLE | RTL_CR_SCHEDULE_ENABLE | RTL_CR_MAC_TX_ENABLE | RTL_CR_MAC_RX_ENABLE
		| RTL_CR_SECURITY_ENABLE | RTL_CR_CALTIMER_ENABLE;
	rtl_w16(RTL_REG_CR, cr);
	return true;
}

bool g_rtl_q_high;
bool g_rtl_q_normal;
bool g_rtl_q_low;
uint g_rtl_q_count;
uint g_rtl_out_mgmt;   // index into g_rtl_ep_out
uint g_rtl_out_be;

fn void rtl_config_endpoints()
{
	uint v = rtl_r16(RTL_REG_NORMAL_SIE_EP_TX);
	g_rtl_q_count = 0;
	if (v & RTL_NORMAL_SIE_EP_TX_HIGH_MASK)   { g_rtl_q_high = true;   g_rtl_q_count++; }
	if (v & RTL_NORMAL_SIE_EP_TX_NORMAL_MASK) { g_rtl_q_normal = true; g_rtl_q_count++; }
	if (v & RTL_NORMAL_SIE_EP_TX_LOW_MASK)    { g_rtl_q_low = true;    g_rtl_q_count++; }
	if (g_rtl_q_count == 0)
	{
		if (g_rtl_nr_out >= 3) { g_rtl_q_low = true; g_rtl_q_count++; }
		if (g_rtl_nr_out >= 2) { g_rtl_q_normal = true; g_rtl_q_count++; }
		if (g_rtl_nr_out >= 1) { g_rtl_q_high = true; g_rtl_q_count++; }
	}
}

fn void rtl_init_reserved_pages()
{
	uint hq = g_rtl_q_high ? RTL_TX_PAGE_NUM_HI_PQ_8192E : 0;
	uint lq = g_rtl_q_low ? RTL_TX_PAGE_NUM_LO_PQ_8192E : 0;
	uint nq = g_rtl_q_normal ? RTL_TX_PAGE_NUM_NORM_PQ_8192E : 0;
	rtl_w32(RTL_REG_RQPN_NPQ, (nq << RTL_RQPN_NPQ_SHIFT));
	uint pubq = RTL_TX_TOTAL_PAGE_NUM_8192E - hq - lq - nq - 1;
	rtl_w32(RTL_REG_RQPN, RTL_RQPN_LOAD | (hq << RTL_RQPN_HI_PQ_SHIFT) | (lq << RTL_RQPN_LO_PQ_SHIFT) | (pubq << RTL_RQPN_PUB_PQ_SHIFT));
}

fn bool rtl_init_queue_priority()
{
	uint hiq; uint mgq; uint bkq; uint beq; uint viq; uint voq;
	uint mgp; uint bep;
	if (g_rtl_q_count == 1)
	{
		uint hi = g_rtl_q_high ? RTL_TRXDMA_QUEUE_HIGH : (g_rtl_q_low ? RTL_TRXDMA_QUEUE_LOW : RTL_TRXDMA_QUEUE_NORMAL);
		hiq = hi; mgq = hi; bkq = hi; beq = hi; viq = hi; voq = hi;
		mgp = 0; bep = 0;
	}
	else if (g_rtl_q_count == 2)
	{
		uint hi;
		uint lo;
		if (g_rtl_q_high && g_rtl_q_low) { hi = RTL_TRXDMA_QUEUE_HIGH; lo = RTL_TRXDMA_QUEUE_LOW; }
		else if (g_rtl_q_normal && g_rtl_q_low) { hi = RTL_TRXDMA_QUEUE_NORMAL; lo = RTL_TRXDMA_QUEUE_LOW; }
		else { hi = RTL_TRXDMA_QUEUE_HIGH; lo = RTL_TRXDMA_QUEUE_NORMAL; }
		hiq = hi; mgq = hi; bkq = lo; beq = lo; viq = hi; voq = hi;
		mgp = 0; bep = 1;
	}
	else if (g_rtl_q_count == 3)
	{
		beq = RTL_TRXDMA_QUEUE_LOW; bkq = RTL_TRXDMA_QUEUE_LOW; viq = RTL_TRXDMA_QUEUE_NORMAL;
		voq = RTL_TRXDMA_QUEUE_HIGH; mgq = RTL_TRXDMA_QUEUE_HIGH; hiq = RTL_TRXDMA_QUEUE_HIGH;
		mgp = mgq ^ 3; bep = beq ^ 3;
	}
	else
	{
		return false;
	}
	uint v = rtl_r16(RTL_REG_TRXDMA_CTRL) & 7;
	v |= (voq << RTL_TRXDMA_CTRL_VOQ_SHIFT) | (viq << RTL_TRXDMA_CTRL_VIQ_SHIFT) | (beq << RTL_TRXDMA_CTRL_BEQ_SHIFT)
		| (bkq << RTL_TRXDMA_CTRL_BKQ_SHIFT) | (mgq << RTL_TRXDMA_CTRL_MGQ_SHIFT) | (hiq << RTL_TRXDMA_CTRL_HIQ_SHIFT);
	// No RX DMA aggregation: one frame per bulk IN transfer, so a transfer
	// always fits usbd's one-page DMA buffer.
	v &= ~RTL_TRXDMA_CTRL_RXDMA_AGG_EN;
	rtl_w16(RTL_REG_TRXDMA_CTRL, v);
	g_rtl_out_mgmt = mgp < g_rtl_nr_out ? mgp : 0;
	g_rtl_out_be = bep < g_rtl_nr_out ? bep : 0;
	return true;
}

// --- MAC / BB / RF -------------------------------------------------------

fn void rtl_init_mac()
{
	foreach (e : RTL8192E_MAC_INIT)
	{
		if (e.reg == 0xFFFF) { break; }
		rtl_w8(e.reg, (uint)e.val);
	}
}

fn void rtl_phy_regs(Rtl_reg32[] tab)
{
	foreach (e : tab)
	{
		if (e.reg == 0xFFFF) { break; }
		rtl_w32(e.reg, e.val);
		rtl_udelay(1);
	}
}

fn void rtl_init_phy_bb()
{
	uint v = rtl_r16(RTL_REG_SYS_FUNC);
	rtl_w16(RTL_REG_SYS_FUNC, v | RTL_SYS_FUNC_BB_GLB_RSTN | RTL_SYS_FUNC_BBRSTB | RTL_SYS_FUNC_DIO_RF);
	rtl_w8(RTL_REG_RF_CTRL, RTL_RF_ENABLE | RTL_RF_RSTB | RTL_RF_SDMRSTB);
	v = rtl_r16(RTL_REG_SYS_FUNC);
	rtl_w16(RTL_REG_SYS_FUNC, v | RTL_SYS_FUNC_USBA | RTL_SYS_FUNC_USBD | RTL_SYS_FUNC_DIO_RF | RTL_SYS_FUNC_BB_GLB_RSTN | RTL_SYS_FUNC_BBRSTB);
	rtl_w8(RTL_REG_RF_CTRL, RTL_RF_ENABLE | RTL_RF_RSTB | RTL_RF_SDMRSTB);
	rtl_phy_regs(RTL8192EU_PHY_INIT[..]);
	rtl_phy_regs(RTL8192EU_AGC_STD[..]);
	if (g_rtl_tx_paths == 1)
	{
		// 1T2R boards transmit on path B.
		uint t = rtl_r32(RTL_REG_FPGA0_TX_INFO);
		rtl_w32(RTL_REG_FPGA0_TX_INFO, (t & ~3u) | 2);
		t = rtl_r32(RTL_REG_FPGA1_TX_INFO);
		rtl_w32(RTL_REG_FPGA1_TX_INFO, (t & ~0x300033u) | 0x200022);
		t = rtl_r32(RTL_REG_CCK0_AFE_SETTING);
		t &= ~RTL_CCK0_AFE_RX_MASK;
		t &= 0x00FFFFFF;
		t |= 0x40000000 | RTL_CCK0_AFE_RX_ANT_B;
		rtl_w32(RTL_REG_CCK0_AFE_SETTING, t);
		t = rtl_r32(RTL_REG_OFDM0_TRX_PATH_ENABLE);
		t &= ~(RTL_OFDM_RF_PATH_RX_MASK | RTL_OFDM_RF_PATH_TX_MASK);
		t |= RTL_OFDM_RF_PATH_RX_A | RTL_OFDM_RF_PATH_RX_B | RTL_OFDM_RF_PATH_TX_B;
		rtl_w32(RTL_REG_OFDM0_TRX_PATH_ENABLE, t);
		t = rtl_r32(RTL_REG_OFDM0_AGC_PARM1);
		rtl_w32(RTL_REG_OFDM0_AGC_PARM1, (t & ~0x30u) | 0x10);
		uint[5] regs = { RTL_REG_TX_CCK_RFON, RTL_REG_TX_CCK_BBON, RTL_REG_TX_OFDM_RFON, RTL_REG_TX_OFDM_BBON, RTL_REG_TX_TO_TX };
		for (int i = 0; i < 5; i++)
		{
			t = rtl_r32(regs[i]);
			rtl_w32(regs[i], (t & ~(3u << 26)) | (1u << 27));
		}
	}
	rtl_w32(RTL_REG_AFE_XTAL_CTRL, 0x000F81FB);
}

fn void rtl_init_rf_path(Rtl_rf[] tab, uint path)
{
	uint sw = path == 0 ? RTL_REG_FPGA0_XA_RF_SW_CTRL : RTL_REG_FPGA0_XB_RF_SW_CTRL;
	uint oe = path == 0 ? RTL_REG_FPGA0_XA_RF_INT_OE : RTL_REG_FPGA0_XB_RF_INT_OE;
	uint p2 = rtl_rf_hssi2(path);
	uint env = rtl_r16(sw) & RTL_FPGA0_RF_RFENV;
	rtl_w32(oe, rtl_r32(oe) | (1u << 20));
	rtl_udelay(1);
	rtl_w32(oe, rtl_r32(oe) | (1u << 4));
	rtl_udelay(1);
	rtl_w32(p2, rtl_r32(p2) & ~RTL_FPGA0_HSSI_3WIRE_ADDR_LEN);
	rtl_udelay(1);
	rtl_w32(p2, rtl_r32(p2) & ~RTL_FPGA0_HSSI_3WIRE_DATA_LEN);
	rtl_udelay(1);
	foreach (e : tab)
	{
		uint reg = (uint)e.reg;
		if (reg == 0xFF) { break; }
		switch (reg)
		{
			case 0xFE: rtl_mdelay(50); continue;
			case 0xFD: rtl_mdelay(5); continue;
			case 0xFC: rtl_mdelay(1); continue;
			case 0xFB: rtl_udelay(50); continue;
			case 0xFA: rtl_udelay(5); continue;
			case 0xF9: rtl_udelay(1); continue;
			default: break;
		}
		rtl_rf_write(path, reg, e.val);
		rtl_udelay(1);
	}
	uint s = rtl_r16(sw) & ~RTL_FPGA0_RF_RFENV;
	rtl_w16(sw, s | env);
}

fn bool rtl_auto_llt()
{
	rtl_w32(RTL_REG_AUTO_LLT, rtl_r32(RTL_REG_AUTO_LLT) | RTL_AUTO_LLT_INIT_LLT);
	for (int i = 0; i < 500; i++)
	{
		if ((rtl_r32(RTL_REG_AUTO_LLT) & RTL_AUTO_LLT_INIT_LLT) == 0) { return true; }
		rtl_udelay(3);
	}
	return false;
}

// TX power from the efuse, path A (and B on a 2T board), channel group
// `ch`'s CCK and HT40-1S bases (8192E).
fn void rtl_set_tx_power(uint channel)
{
	uint group = channel < 3 ? 0 : (channel < 6 ? 1 : (channel < 9 ? 2 : (channel < 12 ? 3 : 4)));
	uint cck = (uint)g_rtl_efuse[0x10 + group];
	uint v = rtl_r32(RTL_REG_TX_AGC_A_CCK1_MCS32);
	rtl_w32(RTL_REG_TX_AGC_A_CCK1_MCS32, (v & 0xFFFF00FF) | (cck << 8));
	v = rtl_r32(RTL_REG_TX_AGC_B_CCK11_A_CCK2_11);
	rtl_w32(RTL_REG_TX_AGC_B_CCK11_A_CCK2_11, (v & 0xFF) | (cck << 8) | (cck << 16) | (cck << 24));
	uint base = (uint)g_rtl_efuse[0x16 + group];
	uint ofdm = base | (base << 8) | (base << 16) | (base << 24);
	rtl_w32(RTL_REG_TX_AGC_A_RATE18_06, ofdm);
	rtl_w32(RTL_REG_TX_AGC_A_RATE54_24, ofdm);
	uint ht20 = ((uint)g_rtl_efuse[0x1B] >> 4) & 0xF;   // 4-bit signed diff, path A
	uint mcsb = (base + (ht20 & 0x8 ? ht20 | 0xFFFFFFF0 : ht20)) & 0xFF;
	uint mcs = mcsb | (mcsb << 8) | (mcsb << 16) | (mcsb << 24);
	rtl_w32(RTL_REG_TX_AGC_A_MCS03_MCS00, mcs);
	rtl_w32(RTL_REG_TX_AGC_A_MCS07_MCS04, mcs);
	rtl_w32(RTL_REG_TX_AGC_A_MCS11_MCS08, mcs);
	rtl_w32(RTL_REG_TX_AGC_A_MCS15_MCS12, mcs);
	if (g_rtl_tx_paths > 1)
	{
		uint cckb = (uint)g_rtl_efuse[0x3A + group];
		v = rtl_r32(RTL_REG_TX_AGC_B_CCK1_55_MCS32);
		rtl_w32(RTL_REG_TX_AGC_B_CCK1_55_MCS32, (v & 0xFF) | (cckb << 8) | (cckb << 16) | (cckb << 24));
		v = rtl_r32(RTL_REG_TX_AGC_B_CCK11_A_CCK2_11);
		rtl_w32(RTL_REG_TX_AGC_B_CCK11_A_CCK2_11, (v & 0xFFFFFF00) | cckb);
		uint baseb = (uint)g_rtl_efuse[0x3A + 6 + group];
		uint ofdmb = baseb | (baseb << 8) | (baseb << 16) | (baseb << 24);
		rtl_w32(RTL_REG_TX_AGC_B_RATE18_06, ofdmb);
		rtl_w32(RTL_REG_TX_AGC_B_RATE54_24, ofdmb);
		rtl_w32(RTL_REG_TX_AGC_B_MCS03_MCS00, ofdmb);
		rtl_w32(RTL_REG_TX_AGC_B_MCS07_MCS04, ofdmb);
		rtl_w32(RTL_REG_TX_AGC_B_MCS11_MCS08, ofdmb);
		rtl_w32(RTL_REG_TX_AGC_B_MCS15_MCS12, ofdmb);
	}
}

fn void rtl_lc_calibrate()
{
	uint lstf = rtl_r32(RTL_REG_OFDM1_LSTF);
	uint am = 0;
	uint bm = 0;
	bool cont = (lstf & RTL_OFDM_LSTF_MASK) != 0;
	if (cont)
	{
		rtl_w32(RTL_REG_OFDM1_LSTF, lstf & ~RTL_OFDM_LSTF_MASK);
		am = rtl_rf_read(0, RTL_RF6052_REG_AC);
		rtl_rf_write(0, RTL_RF6052_REG_AC, (am & 0x8FFFF) | 0x10000);
		if (g_rtl_tx_paths > 1)
		{
			bm = rtl_rf_read(1, RTL_RF6052_REG_AC);
			rtl_rf_write(1, RTL_RF6052_REG_AC, (bm & 0x8FFFF) | 0x10000);
		}
	}
	else
	{
		rtl_w8(RTL_REG_TXPAUSE, 0xFF);
	}
	uint v = rtl_rf_read(0, RTL_RF6052_REG_MODE_AG);
	rtl_rf_write(0, RTL_RF6052_REG_MODE_AG, v | 0x08000);
	rtl_mdelay(100);
	if (cont)
	{
		rtl_w32(RTL_REG_OFDM1_LSTF, lstf);
		rtl_rf_write(0, RTL_RF6052_REG_AC, am);
		if (g_rtl_tx_paths > 1) { rtl_rf_write(1, RTL_RF6052_REG_AC, bm); }
	}
	else
	{
		rtl_w8(RTL_REG_TXPAUSE, 0);
	}
}

fn void rtl_enable_rf()
{
	rtl_w32(RTL_REG_RX_WAIT_CCA, rtl_r32(RTL_REG_RX_WAIT_CCA) | (3u << 22));
	rtl_w8(RTL_REG_GPIO_MUXCFG, rtl_r8(RTL_REG_GPIO_MUXCFG) | 0x20);
	rtl_w8(RTL_REG_WLAN_ACT_CONTROL_8723B, 0x04);
	rtl_w32(RTL_REG_PWR_DATA, rtl_r32(RTL_REG_PWR_DATA) | RTL_PWR_DATA_EEPRPAD_RFE_CTRL_EN);
	rtl_w32(RTL_REG_RFE_BUFFER, rtl_r32(RTL_REG_RFE_BUFFER) | 3);
	rtl_w8(RTL_REG_RFE_CTRL_ANTA_SRC, 0x77);
	uint led = rtl_r32(RTL_REG_LEDCFG0);
	rtl_w32(RTL_REG_LEDCFG0, (led & ~(1u << 24)) | (1u << 23));
	rtl_w8(RTL_REG_PAD_CTRL1, rtl_r8(RTL_REG_PAD_CTRL1) & ~1u);
	rtl_w8(RTL_REG_TXPAUSE, 0);
}

// 20 MHz, legacy (no HT) on `channel` (1..13).
fn void rtl_set_channel(uint channel)
{
	uint bw = rtl_r16(RTL_REG_WMAC_TRXPTCL_CTL) & ~RTL_WMAC_TRXPTCL_CTL_BW_MASK;
	bw |= RTL_WMAC_TRXPTCL_CTL_BW_20;
	rtl_w32(RTL_REG_FPGA0_RF_MODE, rtl_r32(RTL_REG_FPGA0_RF_MODE) & ~RTL_FPGA_RF_MODE);
	rtl_w32(RTL_REG_FPGA1_RF_MODE, rtl_r32(RTL_REG_FPGA1_RF_MODE) & ~RTL_FPGA_RF_MODE);
	rtl_w32(RTL_REG_OFDM0_TX_PSDO_NOISE_WEIGHT, rtl_r32(RTL_REG_OFDM0_TX_PSDO_NOISE_WEIGHT) & ~(3u << 30));
	for (uint p = 0; p < 2; p++)
	{
		uint v = rtl_rf_read(p, RTL_RF6052_REG_MODE_AG);
		rtl_rf_write(p, RTL_RF6052_REG_MODE_AG, (v & ~RTL_MODE_AG_CHANNEL_MASK) | channel);
	}
	rtl_w16(RTL_REG_WMAC_TRXPTCL_CTL, bw);
	rtl_w8(RTL_REG_DATA_SUBCHANNEL, 0);
	rtl_w8(RTL_REG_SIFS_CCK + 1, 0x0A);
	rtl_w8(RTL_REG_SIFS_OFDM + 1, 0x0A);
	rtl_w16(RTL_REG_R2T_SIFS, 0x0808);
	rtl_w16(RTL_REG_T2T_SIFS, 0x0A0A);
	for (uint p = 0; p < 2; p++)
	{
		uint v = rtl_rf_read(p, RTL_RF6052_REG_MODE_AG);
		rtl_rf_write(p, RTL_RF6052_REG_MODE_AG, (v & ~RTL_MODE_AG_BW_MASK) | RTL_MODE_AG_BW_20MHZ_8723B);
	}
	rtl_set_tx_power(channel);
	g_rtl_channel = channel;
}

// RX filter: in a scan, every beacon/probe response from every BSS; once
// associated (W4), only our BSSID.
fn void rtl_set_rx_promisc_beacons(bool all)
{
	uint rcr = RTL_RCR_ACCEPT_PHYS_MATCH | RTL_RCR_ACCEPT_MCAST | RTL_RCR_ACCEPT_BCAST
		| RTL_RCR_ACCEPT_MGMT_FRAME | RTL_RCR_HTC_LOC_CTRL | RTL_RCR_APPEND_PHYSTAT
		| RTL_RCR_APPEND_ICV | RTL_RCR_APPEND_MIC;
	if (!all) { rcr |= RTL_RCR_CHECK_BSSID_BEACON | RTL_RCR_CHECK_BSSID_MATCH; }
	rtl_w32(RTL_REG_RCR, rcr);
}

// The whole bring-up, rtl8xxxu_init_device + rtl8xxxu_start for an 8192EU
// station. Print what fails.
fn bool rtl_init_device()
{
	if (!rtl_power_on()) { return false; }
	rtl_init_reserved_pages();
	if (!rtl_init_queue_priority()) { print("wifi: bad TX queue setup\n"); return false; }
	rtl_w16(RTL_REG_TRXFF_BNDY + 2, 0x3CFF);
	bool fw_ok = false;
	for (int tries = 0; tries < 5 && !fw_ok; tries++) { fw_ok = rtl_download_firmware(); }
	if (!fw_ok) { print("wifi: firmware download failed\n"); return false; }
	if (!rtl_start_firmware()) { return false; }
	print("wifi: firmware running\n");

	rtl_init_mac();
	rtl_init_phy_bb();
	rtl_init_rf_path(RTL8192EU_RADIOA_INIT[..], 0);
	rtl_init_rf_path(RTL8192EU_RADIOB_INIT[..], 1);

	uint sw = RTL_FPGA0_RF_TRSW | RTL_FPGA0_RF_TRSWB | RTL_FPGA0_RF_ANTSW | RTL_FPGA0_RF_ANTSWB
		| ((RTL_FPGA0_RF_ANTSW | RTL_FPGA0_RF_ANTSWB) << RTL_FPGA0_RF_BD_CTRL_SHIFT)
		| RTL_FPGA0_RF_PAPE | (RTL_FPGA0_RF_PAPE << RTL_FPGA0_RF_BD_CTRL_SHIFT);
	rtl_w32(RTL_REG_FPGA0_XAB_RF_SW_CTRL, sw);

	uint bnd = RTL_TX_TOTAL_PAGE_NUM_8192E + 1;
	rtl_w8(RTL_REG_TXPKTBUF_BCNQ_BDNY, bnd);
	rtl_w8(RTL_REG_TXPKTBUF_MGQ_BDNY, bnd);
	rtl_w8(RTL_REG_TXPKTBUF_WMAC_LBK_BF_HD, bnd);
	rtl_w8(RTL_REG_TRXFF_BNDY, bnd);
	rtl_w8(RTL_REG_TDECTRL + 1, bnd);

	if (!rtl_auto_llt()) { print("wifi: LLT init failed\n"); return false; }
	rtl_w32(RTL_REG_TXDMA_OFFSET_CHK, rtl_r32(RTL_REG_TXDMA_OFFSET_CHK) | RTL_TXDMA_OFFSET_DROP_DATA_EN);

	rtl_w8(RTL_REG_RX_DRVINFO_SZ, 4);
	rtl_w32(RTL_REG_HIMR0, 0);
	rtl_w32(RTL_REG_HIMR1, 0);
	rtl_set_rx_promisc_beacons(true);
	rtl_w32(RTL_REG_MAR, 0xFFFFFFFF);
	rtl_w32(RTL_REG_MAR + 4, 0xFFFFFFFF);

	uint rr = rtl_r32(RTL_REG_RESPONSE_RATE_SET);
	rtl_w32(RTL_REG_RESPONSE_RATE_SET, (rr & ~RTL_RESPONSE_RATE_BITMAP_ALL) | RTL_RESPONSE_RATE_RRSR_CCK_ONLY_1M);
	rtl_w16(RTL_REG_SPEC_SIFS, ((0x0Au << RTL_SPEC_SIFS_CCK_SHIFT) & RTL_SPEC_SIFS_CCK_MASK) | ((0x10u << RTL_SPEC_SIFS_OFDM_SHIFT) & RTL_SPEC_SIFS_OFDM_MASK));
	rtl_w16(RTL_REG_RETRY_LIMIT, ((0x30u << RTL_RETRY_LIMIT_SHORT_SHIFT) & RTL_RETRY_LIMIT_SHORT_MASK) | ((0x30u << RTL_RETRY_LIMIT_LONG_SHIFT) & RTL_RETRY_LIMIT_LONG_MASK));
	rtl_w16(RTL_REG_MAC_SPEC_SIFS, 0x100A);
	rtl_w16(RTL_REG_SIFS_CCK, 0x100A);
	rtl_w16(RTL_REG_SIFS_OFDM, 0x100A);
	rtl_w32(RTL_REG_EDCA_BE_PARAM, 0x005EA42B);
	rtl_w32(RTL_REG_EDCA_BK_PARAM, 0x0000A44F);
	rtl_w32(RTL_REG_EDCA_VI_PARAM, 0x005EA324);
	rtl_w32(RTL_REG_EDCA_VO_PARAM, 0x002FA226);
	rtl_w32(RTL_REG_DARFRC, 0);
	rtl_w32(RTL_REG_DARFRC + 4, 0x10080404);
	rtl_w32(RTL_REG_RARFRC, 0x04030201);
	rtl_w32(RTL_REG_RARFRC + 4, 0x08070605);
	rtl_w8(RTL_REG_FWHW_TXQ_CTRL, rtl_r8(RTL_REG_FWHW_TXQ_CTRL) | RTL_FWHW_TXQ_CTRL_AMPDU_RETRY);
	rtl_w8(RTL_REG_ACKTO, 0x40);
	rtl_w16(RTL_REG_BEACON_CTRL, RTL_BEACON_DISABLE_TSF_UPDATE | (RTL_BEACON_DISABLE_TSF_UPDATE << 8));
	rtl_w16(RTL_REG_TBTT_PROHIBIT, 0x6404);
	rtl_w8(RTL_REG_DRIVER_EARLY_INT, RTL_DRIVER_EARLY_INT_TIME);
	rtl_w8(RTL_REG_BEACON_DMA_TIME, RTL_BEACON_DMA_ATIME_INT_TIME);
	rtl_w16(RTL_REG_BEACON_TCFG, 0x660F);
	rtl_w32(RTL_REG_FPGA0_RF_MODE, rtl_r32(RTL_REG_FPGA0_RF_MODE) | RTL_FPGA_RF_MODE_CCK | RTL_FPGA_RF_MODE_OFDM);
	rtl_w32(RTL_REG_CAM_CMD, RTL_CAM_CMD_POLLING | (1u << 30));   // invalidate the key CAM
	rtl_set_tx_power(1);
	rtl_w8(RTL_REG_HWSEQ_CTRL, 0xFF);
	rtl_w32(RTL_REG_BAR_MODE_CTRL, 0x0201FFFF);
	rtl_w16(RTL_REG_FAST_EDCA_CTRL, 0);
	rtl_w8(RTL_REG_QUEUE_CTRL, rtl_r8(RTL_REG_QUEUE_CTRL) & ~8u);
	rtl_w8(RTL_REG_ACLK_MON, 0);
	rtl_lc_calibrate();
	rtl_rf_write(0, RTL_RF6052_REG_T_METER_8723B, 0x37CF8);
	rtl_w8(RTL_REG_NAV_UPPER, (30000 + RTL_NAV_UPPER_UNIT - 1) / RTL_NAV_UPPER_UNIT);
	rtl_w8(RTL_REG_USB_HRPWM, 0);
	rtl_w32(RTL_REG_FWHW_TXQ_CTRL, rtl_r32(RTL_REG_FWHW_TXQ_CTRL) | RTL_FWHW_TXQ_CTRL_XMIT_MGMT_ACK);
	g_rtl_cck_agc_hi = (rtl_r32(RTL_REG_FPGA0_XA_HSSI_PARM2) & RTL_FPGA0_HSSI_PARM2_CCK_HIGH_PWR) != 0;
	uint afe = rtl_r32(RTL_REG_AFE_MISC);
	rtl_w8(RTL_REG_8192E_LDOV12_CTRL, 0x75);
	rtl_w32(RTL_REG_AFE_MISC, (afe & 0xFFF00FFF) | 0x0007E000);

	// start
	rtl_enable_rf();
	rtl_w16(RTL_REG_RXFLTMAP2, 0xFFFF);
	rtl_w16(RTL_REG_RXFLTMAP0, 0xFFFF);
	uint igi = rtl_r32(RTL_REG_OFDM0_XA_AGC_CORE1);
	rtl_w32(RTL_REG_OFDM0_XA_AGC_CORE1, (igi & ~RTL_OFDM0_X_AGC_CORE1_IGI_MASK) | 0x1E);

	// station on port 0 with our MAC
	for (uint i = 0; i < 6; i++) { rtl_w8(RTL_REG_MACID + i, (uint)g_rtl_mac[i]); }
	rtl_w8(RTL_REG_MSR, (rtl_r8(RTL_REG_MSR) & 0x0C) | RTL_MSR_LINKTYPE_STATION);
	rtl_set_channel(1);
	return true;
}

// --- RX ------------------------------------------------------------------

// One non-blocking bulk IN attempt (usb_bulk_transfer would sit on NAKs
// for up to 3 s). Bytes received, 0 = nothing (NAK), -1 = error.
fn int rtl_bulk_in_poll(char* buf, uint len)
{
	uint packets = (len + g_rtl_ep_in_mps - 1) / g_rtl_ep_in_mps;
	uint actual = 0;
	int r = hc_transfer_once(g_rtl_dev, g_rtl_ep_in, USB_HCCHAR_EPTYPE_BULK, true, g_rtl_pid_in, g_rtl_ep_in_mps, len, packets, &actual);
	if (r == 1) { return 0; }
	if (r != 0) { return -1; }
	g_rtl_pid_in = (usb_reg_read(USB_HC0_HCTSIZ) >> USB_HCTSIZ_PID_SHIFT) & 0x3;
	if (actual > len) { actual = len; }
	mem::copy(buf, (void*)usb_dma_paddr, actual);
	return (int)actual;
}

fn bool rtl_mac_eq(char* a, char* b)
{
	for (int i = 0; i < 6; i++) { if (a[i] != b[i]) { return false; } }
	return true;
}

fn void rtl_note_bss(char* f, uint len, int rssi)
{
	// beacon / probe response: 24-byte header, 12 fixed bytes, then IEs
	if (len < 36) { return; }
	char* bssid = &f[16];
	uint cap = (uint)f[34] | ((uint)f[35] << 8);
	char[33] ssid;
	ssid[0] = 0;
	uint channel = g_rtl_channel;
	bool rsn = false;
	uint rsn_why = 0;
	uint at = 36;
	while (at + 2 <= len)
	{
		uint id = (uint)f[at];
		uint l = (uint)f[at + 1];
		if (at + 2 + l > len) { break; }
		if (id == 0 && l <= 32)
		{
			for (uint i = 0; i < l; i++) { ssid[i] = f[at + 2 + i]; }
			ssid[l] = 0;
		}
		else if (id == 3 && l >= 1) { channel = (uint)f[at + 2]; }
		else if (id == 48) { rsn = true; rsn_why = rtl_rsn_check(&f[at + 2], l); }
		at += 2 + l;
	}
	int slot = -1;
	for (int i = 0; i < RTL_BSS_MAX; i++)
	{
		if (g_rtl_bss[i].used && rtl_mac_eq(&g_rtl_bss[i].bssid[0], bssid)) { slot = i; break; }
	}
	if (slot < 0)
	{
		for (int i = 0; i < RTL_BSS_MAX; i++) { if (!g_rtl_bss[i].used) { slot = i; break; } }
	}
	if (slot < 0) { return; }
	Rtl_bss* b = &g_rtl_bss[slot];
	b.used = true;
	for (int i = 0; i < 6; i++) { b.bssid[i] = bssid[i]; }
	for (int i = 0; i < 33; i++) { b.ssid[i] = ssid[i]; }
	b.channel = channel;
	b.rssi = rssi;
	b.privacy = (cap & 0x10) != 0;
	b.rsn = rsn;
	b.rsn_why = rsn_why;
	b.last_seen = rdtime();
}

// One received bulk transfer: rxdesc24 + drvinfo + shift + the frame.
fn void rtl_rx_transfer(char* buf, int n)
{
	int at = 0;
	while (at + 24 <= n)
	{
		uint d0 = (uint)buf[at] | ((uint)buf[at + 1] << 8) | ((uint)buf[at + 2] << 16) | ((uint)buf[at + 3] << 24);
		uint d2 = (uint)buf[at + 8] | ((uint)buf[at + 9] << 8) | ((uint)buf[at + 10] << 16) | ((uint)buf[at + 11] << 24);
		uint pktlen = d0 & 0x3FFF;
		bool crc = (d0 & (1u << 14)) != 0;
		uint drvinfo = ((d0 >> 16) & 0xF) * 8;
		uint shift = (d0 >> 24) & 0x3;
		bool phy = (d0 & (1u << 26)) != 0;
		bool c2h = (d2 & (1u << 28)) != 0;
		bool hw_dec = ((d0 >> 20) & 7) != 0 && (d0 & (1u << 27)) == 0;   // security type set, not swdec
		int frame = at + 24 + (int)drvinfo + (int)shift;
		if (pktlen == 0 || frame + (int)pktlen > n) { break; }
		if (!crc && !c2h)
		{
			g_rtl_rx_frames++;
			char* f = &buf[frame];
			int rssi = 0;
			if (phy && drvinfo >= 8)
			{
				// PHY status (rtl8723au_phy_stats): byte 4 is the OFDM
				// power, byte 5 the CCK AGC report (8192E: LNA/VGA index).
				uint d3 = (uint)buf[at + 12];
				char* ps = &buf[at + 24];
				if ((d3 & 0x7F) < 4)
				{
					uint agc = (uint)ps[5];
					int[8] lna0 = { 15, 9, -10, -21, -23, -27, -43, -44 };
					int[8] lna1 = { 24, 18, 13, -4, -11, -18, -31, -36 };
					uint li = (agc & RTL_CCK_AGC_RPT_LNA_IDX_MASK) >> 5;
					uint vi = agc & RTL_CCK_AGC_RPT_VGA_IDX_MASK;
					rssi = (g_rtl_cck_agc_hi ? lna1[li] : lna0[li]) - 2 * (int)vi;
				}
				else
				{
					rssi = (int)((uint)ps[4] >> 1) - 110;
				}
			}
			uint fc = (uint)f[0];
			if ((fc & 0x0C) == 0 && ((fc & 0xF0) == 0x80 || (fc & 0xF0) == 0x50))
			{
				rtl_note_bss(f, pktlen, rssi);
			}
			else
			{
				rtl_rx_frame(f, pktlen, hw_dec);   // the station / data path
			}
		}
		else if (crc)
		{
			g_rtl_rx_errors++;
		}
		uint total = 24 + drvinfo + shift + pktlen;
		at += (int)((total + 7) & ~7u);
	}
}

// --- TX -------------------------------------------------------------------

// Send one 802.11 frame (`f`, `len` bytes, no FCS) with a 40-byte TX
// descriptor, on the management queue or the best-effort data queue.
// Fixed rates: 1 Mb/s CCK for management, 11 Mb/s CCK for data; no
// aggregation, no rate adaptation.
fn bool rtl_tx(char* f, uint len, bool mgmt, bool aes)
{
	usb_set_split_context(false, 0, 0, false);
	char[2400] pkt;
	if (len + RTL_TX_DESC > 2400) { return false; }
	for (uint i = 0; i < RTL_TX_DESC; i++) { pkt[i] = 0; }
	pkt[0] = (char)len;
	pkt[1] = (char)(len >> 8);
	pkt[2] = (char)RTL_TX_DESC;
	uint dw0 = RTL_TXDESC_OWN | RTL_TXDESC_FIRST_SEGMENT | RTL_TXDESC_LAST_SEGMENT;
	if (((uint)f[4] & 1) != 0) { dw0 |= RTL_TXDESC_BROADMULTICAST; }   // DA multicast/broadcast
	pkt[3] = (char)dw0;
	uint queue = mgmt ? RTL_TXDESC_QUEUE_MGNT : RTL_TXDESC_QUEUE_BE;
	uint dw1 = queue << RTL_TXDESC_QUEUE_SHIFT;
	if (aes) { dw1 |= RTL_TXDESC_SEC_AES; }
	uint dw2 = RTL_TXDESC40_AGG_BREAK;
	uint dw3 = RTL_TXDESC40_USE_DRIVER_RATE;
	uint rate = mgmt ? RTL_DESC_RATE_1M : RTL_DESC_RATE_11M;
	uint dw4 = rate | (6u << RTL_TXDESC40_RETRY_LIMIT_SHIFT) | RTL_TXDESC40_RETRY_LIMIT_ENABLE;
	uint dw8 = RTL_TXDESC40_HW_SEQ_ENABLE;
	uint[4] dws = { dw1, dw2, dw3, dw4 };
	for (uint k = 0; k < 4; k++)
	{
		uint o = 4 + k * 4;
		uint v = dws[k];
		pkt[o] = (char)v; pkt[o + 1] = (char)(v >> 8); pkt[o + 2] = (char)(v >> 16); pkt[o + 3] = (char)(v >> 24);
	}
	pkt[32] = (char)dw8; pkt[33] = (char)(dw8 >> 8); pkt[34] = (char)(dw8 >> 16); pkt[35] = (char)(dw8 >> 24);
	// checksum: XOR of the first 32 bytes as 16-bit words, csum field (bytes 28..29) zero
	uint csum = 0;
	for (uint i = 0; i < 32; i += 2) { csum ^= (uint)pkt[i] | ((uint)pkt[i + 1] << 8); }
	pkt[28] = (char)csum;
	pkt[29] = (char)(csum >> 8);
	mem::copy(&pkt[RTL_TX_DESC], f, len);
	uint q = mgmt ? g_rtl_out_mgmt : g_rtl_out_be;
	uint actual;
	return usb_bulk_transfer(g_rtl_dev, g_rtl_ep_out[q], 512, &g_rtl_pid_out[q], false, &pkt[0], len + RTL_TX_DESC, &actual);
}

// --- probe / poll / scan ----------------------------------------------------

fn bool rtl_match(uint vid, uint pid)
{
	// rtl8xxxu's 8192EU entries
	return (vid == 0x2357 && (pid == 0x0109 || pid == 0x0108 || pid == 0x0107 || pid == 0x0122))
		|| (vid == 0x0BDA && (pid == 0x818B || pid == 0x818C))
		|| (vid == 0x2001 && (pid == 0x3319 || pid == 0x331b || pid == 0x3322))
		|| (vid == 0x07B8 && pid == 0x8179)
		|| (vid == 0x050D && pid == 0x1109);
}

// Called from usb_enumerate_hub_port_device once a matching device has an
// address and its configuration descriptor is in `cfg`.
fn void rtl_probe(uint dev_addr, uint mps0, char* cfg, uint cfg_len)
{
	if (!usb_set_configuration(dev_addr, mps0, 1)) { print("wifi: SET_CONFIGURATION failed\n"); return; }
	g_rtl_dev = dev_addr;
	g_rtl_mps0 = mps0;
	g_rtl_nr_out = 0;
	g_rtl_ep_in = 0;
	uint at = 0;
	while (at + 2 <= cfg_len)
	{
		uint l = (uint)cfg[at];
		if (l < 2) { break; }
		if ((uint)cfg[at + 1] == 5 && l >= 7)   // endpoint descriptor
		{
			uint ea = (uint)cfg[at + 2];
			uint attr = (uint)cfg[at + 3] & 3;
			uint mps = (uint)cfg[at + 4] | ((uint)cfg[at + 5] << 8);
			if (attr == 2)
			{
				if ((ea & 0x80) != 0) { if (g_rtl_ep_in == 0) { g_rtl_ep_in = ea & 0x0F; g_rtl_ep_in_mps = mps; } }
				else if (g_rtl_nr_out < 3) { g_rtl_ep_out[g_rtl_nr_out] = ea & 0x0F; g_rtl_nr_out++; }
			}
		}
		at += l;
	}
	g_rtl_pid_in = USB_PID_DATA0;
	for (int i = 0; i < 3; i++) { g_rtl_pid_out[i] = USB_PID_DATA0; }
	if (g_rtl_ep_in == 0 || g_rtl_nr_out == 0) { print("wifi: endpoints not found\n"); return; }

	uint sys_cfg = rtl_r32(RTL_REG_SYS_CFG);
	uint bond = rtl_r32(RTL_REG_HPON_FSM) & RTL_HPON_FSM_BONDING_MASK;
	g_rtl_tx_paths = bond == RTL_HPON_FSM_BONDING_1T2R ? 1 : 2;
	print(g_rtl_tx_paths == 1 ? "wifi: RTL8191EU" : "wifi: RTL8192EU");
	print(" cut ");
	print_uint((sys_cfg & RTL_SYS_CFG_CHIP_VERSION_MASK) >> 12);
	print(", bulk in ep ");
	print_uint(g_rtl_ep_in);
	print(", ");
	print_uint(g_rtl_nr_out);
	print(" out eps\n");
	rtl_config_endpoints();
	if (!rtl_read_efuse()) { print("wifi: efuse read failed\n"); return; }
	print("wifi: mac=");
	for (int i = 0; i < 6; i++) { print_hex8((uint)g_rtl_mac[i]); if (i < 5) { putchar(':'); } }
	print("\n");
	if (!rtl_load_firmware()) { print("wifi: no /lib/firmware/rtl8192eu_nic.bin\n"); return; }
	if (!rtl_init_device()) { print("wifi: bring-up failed\n"); return; }
	g_rtl_present = true;
	g_rtl_up = true;
	rtl_link_init();
	print("wifi: up, scanning\n");
	rtl_scan_start();
}

fn void rtl_scan_start()
{
	for (int i = 0; i < RTL_BSS_MAX; i++) { g_rtl_bss[i].used = false; }
	rtl_set_rx_promisc_beacons(true);
	g_rtl_scanning = true;
	g_rtl_scan_ch = 1;
	rtl_set_channel(1);
	g_rtl_scan_next = rdtime() + usb_us_to_ticks(200000);
}

// usbd's fast loop: drain RX, run the scan clock and the station logic.
fn void rtl_poll()
{
	if (!g_rtl_up) { return; }
	// The dongle is high speed: no split transactions. A low/full-speed
	// HID device on another hub port leaves its own split context set.
	usb_set_split_context(false, 0, 0, false);
	for (int k = 0; k < 8; k++)
	{
		int n = rtl_bulk_in_poll(&g_rtl_rx[0], RTL_RX_BUF);
		if (n <= 0) { break; }
		rtl_rx_transfer(&g_rtl_rx[0], n);
	}
	if (g_rtl_link_ok && g_sta_rx_data != g_rtl_kicked) { g_rtl_kicked = g_sta_rx_data; link_kick(&g_rtl_link); }
	rtl_data_tx_drain();
	if (g_rtl_scanning && rdtime() >= g_rtl_scan_next)
	{
		if (g_rtl_scan_ch >= 13)
		{
			g_rtl_scanning = false;
			rtl_scan_done();
			if (!g_rtl_autojoin_tried) { g_rtl_autojoin_tried = true; rtl_autojoin(); }
		}
		else
		{
			g_rtl_scan_ch++;
			rtl_set_channel(g_rtl_scan_ch);
			g_rtl_scan_next = rdtime() + usb_us_to_ticks(200000);
		}
	}
	rtl_station_tick();
}

fn int rtl_scan_text(char* out, int cap)
{
	int n = 0;
	for (int i = 0; i < RTL_BSS_MAX && n < cap - 80; i++)
	{
		Rtl_bss* b = &g_rtl_bss[i];
		if (!b.used) { continue; }
		char* hx = "0123456789abcdef";
		for (int k = 0; k < 6; k++)
		{
			out[n] = hx[((uint)b.bssid[k] >> 4) & 0xF]; out[n + 1] = hx[(uint)b.bssid[k] & 0xF]; n += 2;
			if (k < 5) { out[n] = ':'; n++; }
		}
		out[n] = ' '; n++;
		n += fmt::format_uint(b.channel, &out[n]);
		out[n] = ' '; n++;
		if (b.rssi < 0) { out[n] = '-'; n++; n += fmt::format_uint((uint)(-b.rssi), &out[n]); }
		else { n += fmt::format_uint((uint)b.rssi, &out[n]); }
		out[n] = ' '; n++;
		char* sec = b.rsn ? "wpa2" : (b.privacy ? "wep" : "open");
		for (int k = 0; sec[k] != 0; k++) { out[n] = sec[k]; n++; }
		out[n] = ' '; n++;
		for (int k = 0; b.ssid[k] != 0 && n < cap - 2; k++) { out[n] = b.ssid[k]; n++; }
		out[n] = '\n'; n++;
	}
	return n;
}

fn void rtl_scan_done()
{
	char[2048] t;
	int n = rtl_scan_text(&t[0], 2048);
	print("wifi: scan done, ");
	print_uint((uint)g_rtl_rx_frames);
	print(" frames\n");
	t[n] = 0;
	print(&t[0]);
}

// --- the station: join, open-system auth, association, data path -------
//
// `wifi join <ssid>` picks the strongest BSS with that SSID from the scan
// table (scanning first if it isn't there), tunes to its channel, points
// the MAC's BSSID filter at it, and walks auth (seq 1/2) -> assoc req/resp.
// Each step is retried a few times on a timeout. Once associated the link
// "ether1" goes up and ipd runs DHCP on it. Data frames are converted
// between 802.11 (ToDS/FromDS + LLC/SNAP) and Ethernet II in both
// directions. A deauth/disassoc from the AP drops the link and rejoins.

const uint STA_IDLE     = 0;
const uint STA_SCANNING = 1;   // join pending: waiting for the scan to find the SSID
const uint STA_AUTH     = 2;
const uint STA_ASSOC    = 3;
const uint STA_UP       = 4;
const uint STA_KEYS     = 5;   // associated, WPA2 4-way handshake running
const ulong STA_KEYS_TIMEOUT_US = 5000000;
const uint STA_REJOINS  = 3;   // consecutive failed joins before giving up

const uint STA_TRIES    = 5;
const ulong STA_TIMEOUT_US = 300000;

uint g_sta;
char[33] g_sta_ssid;
char[6] g_sta_bssid;
uint g_sta_channel;
uint g_sta_aid;
uint g_sta_tries;
ulong g_sta_due;
uint g_sta_fail;          // last auth/assoc status code from the AP
uint g_sta_reason;        // last deauth/disassoc reason code
bool g_sta_secure;        // this join is WPA2 (the PMK came with the join request)
uint g_sta_rejoins;
ulong g_sta_rx_data;
ulong g_sta_tx_data;
Link g_rtl_link;
bool g_rtl_link_ok;

fn void rtl_link_init()
{
	g_rtl_link_ok = link_create(&g_rtl_link, "ether1", &g_rtl_mac[0], 1500);
	if (g_rtl_link_ok) { g_rtl_link.h.link_up = 0; }
	else { print("wifi: can't create link ether1\n"); }
}

fn void rtl_link_set(bool up)
{
	if (!g_rtl_link_ok) { return; }
	g_rtl_link.h.link_up = up ? 1 : 0;
	link_kick(&g_rtl_link);
}

fn void put_mac(char* dst, char* src) { for (int i = 0; i < 6; i++) { dst[i] = src[i]; } }

// 24-byte management header to the BSS.
fn void rtl_mgmt_hdr(char* f, uint subtype)
{
	f[0] = (char)subtype; f[1] = 0; f[2] = 0; f[3] = 0;
	put_mac(&f[4], &g_sta_bssid[0]);
	put_mac(&f[10], &g_rtl_mac[0]);
	put_mac(&f[16], &g_sta_bssid[0]);
	f[22] = 0; f[23] = 0;
}

fn void rtl_send_auth()
{
	char[30] f;
	rtl_mgmt_hdr(&f[0], 0xB0);
	f[24] = 0; f[25] = 0;   // open system
	f[26] = 1; f[27] = 0;   // transaction 1
	f[28] = 0; f[29] = 0;
	rtl_tx(&f[0], 30, true, false);
}

fn void rtl_send_assoc()
{
	char[128] f;
	rtl_mgmt_hdr(&f[0], 0x00);
	uint n = 24;
	f[n] = g_sta_secure ? 0x31 : 0x21; f[n + 1] = 0x04; n += 2;   // ESS | privacy? | short preamble | short slot time
	f[n] = 10; f[n + 1] = 0; n += 2;         // listen interval
	uint sl = 0;
	while (sl < 32 && g_sta_ssid[sl] != 0) { sl++; }
	f[n] = 0; f[n + 1] = (char)sl; n += 2;
	for (uint i = 0; i < sl; i++) { f[n + i] = g_sta_ssid[i]; }
	n += sl;
	char[8] rates = { 0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24 };
	f[n] = 1; f[n + 1] = 8; n += 2;
	for (uint i = 0; i < 8; i++) { f[n + i] = rates[i]; }
	n += 8;
	char[4] ext = { 0x30, 0x48, 0x60, 0x6C };
	f[n] = 50; f[n + 1] = 4; n += 2;
	for (uint i = 0; i < 4; i++) { f[n + i] = ext[i]; }
	n += 4;
	if (g_sta_secure)
	{
		for (uint i = 0; i < 22; i++) { f[n + i] = WPA_RSN_IE[i]; }
		n += 22;
	}
	rtl_tx(&f[0], n, true, false);
}

fn void rtl_send_deauth()
{
	char[26] f;
	rtl_mgmt_hdr(&f[0], 0xC0);
	f[24] = 3; f[25] = 0;   // reason: station leaving
	rtl_tx(&f[0], 26, true, false);
}

fn bool rtl_ssid_eq(char* a, char* b)
{
	for (int i = 0; i < 33; i++)
	{
		if (a[i] != b[i]) { return false; }
		if (a[i] == 0) { return true; }
	}
	return true;
}

// The strongest scanned BSS named g_sta_ssid, or -1.
fn int rtl_find_bss()
{
	int best = -1;
	for (int i = 0; i < RTL_BSS_MAX; i++)
	{
		Rtl_bss* b = &g_rtl_bss[i];
		if (!b.used || !rtl_ssid_eq(&b.ssid[0], &g_sta_ssid[0])) { continue; }
		if (best < 0 || b.rssi > g_rtl_bss[best].rssi) { best = i; }
	}
	return best;
}

fn void rtl_set_bssid(char* bssid)
{
	for (uint i = 0; i < 6; i++) { rtl_w8(RTL_REG_BSSID + i, (uint)bssid[i]); }
}

fn void rtl_sta_step(uint state)
{
	g_sta = state;
	g_sta_tries = 0;
	g_sta_due = 0;   // send at once
}

// Start (or restart) the join to g_sta_ssid.
fn void rtl_join_start()
{
	if (g_sta == STA_UP || g_sta == STA_ASSOC || g_sta == STA_KEYS) { rtl_link_set(false); }
	rtl_keys_clear();
	int b = rtl_find_bss();
	if (b < 0)
	{
		g_sta = STA_SCANNING;
		if (!g_rtl_scanning) { rtl_scan_start(); }
		return;
	}
	g_rtl_scanning = false;
	put_mac(&g_sta_bssid[0], &g_rtl_bss[b].bssid[0]);
	g_sta_channel = g_rtl_bss[b].channel;
	g_sta_secure = g_rtl_bss[b].privacy || g_rtl_bss[b].rsn;
	char* refuse = null;
	if (g_sta_secure && !g_rtl_bss[b].rsn) { refuse = rtl_rsn_why_text(6); }
	else if (g_sta_secure && g_rtl_bss[b].rsn_why != 0) { refuse = rtl_rsn_why_text(g_rtl_bss[b].rsn_why); }
	else if (g_sta_secure && !g_wpa_have_pmk) { refuse = "it needs a passphrase: wifi join SSID PASSPHRASE"; }
	if (refuse != null)
	{
		print("wifi: can't join ");
		print(&g_sta_ssid[0]);
		print(": ");
		print(refuse);
		print("\n");
		g_sta = STA_IDLE;
		return;
	}
	rtl_set_channel(g_sta_channel);
	rtl_set_bssid(&g_sta_bssid[0]);
	rtl_set_rx_promisc_beacons(false);
	print("wifi: joining ");
	print(&g_sta_ssid[0]);
	print(" on ch ");
	print_uint(g_sta_channel);
	print("\n");
	rtl_sta_step(STA_AUTH);
}

fn void rtl_sta_lost(char* why)
{
	rtl_link_set(false);
	rtl_keys_clear();
	rtl_set_rx_promisc_beacons(true);
	g_sta_rejoins++;
	print("wifi: ");
	print(why);
	if (g_sta_rejoins > STA_REJOINS)
	{
		print(", giving up");
		if (g_sta_secure) { print(" (wrong passphrase?)"); }
		print("\n");
		g_sta = STA_IDLE;
		return;
	}
	print(", rejoining\n");
	rtl_join_start();
}

// The 4-way handshake finished and the keys are in the CAM (rtl_wpa.c3).
fn void rtl_sta_secured()
{
	g_sta = STA_UP;
	g_sta_rejoins = 0;
	print("wifi: WPA2 handshake done, link up\n");
	rtl_link_set(true);
}

fn void rtl_station_tick()
{
	if (g_sta == STA_SCANNING && !g_rtl_scanning)
	{
		// the scan finished: join if the SSID turned up, else scan again
		if (rtl_find_bss() >= 0) { rtl_join_start(); } else { rtl_scan_start(); }
		return;
	}
	if (g_sta == STA_KEYS)
	{
		if (rdtime() >= g_sta_due)
		{
			rtl_send_deauth();
			rtl_sta_lost(g_wpa_mic_fail > 0 ? "4-way handshake failed (MIC mismatch)" : "no 4-way handshake from the AP");
		}
		return;
	}
	if (g_sta != STA_AUTH && g_sta != STA_ASSOC) { return; }
	ulong now = rdtime();
	if (now < g_sta_due) { return; }
	if (g_sta_tries >= STA_TRIES)
	{
		print(g_sta == STA_AUTH ? "wifi: no auth response" : "wifi: no assoc response");
		print("\n");
		rtl_set_rx_promisc_beacons(true);
		g_sta = STA_IDLE;
		return;
	}
	g_sta_tries++;
	if (g_sta == STA_AUTH) { rtl_send_auth(); } else { rtl_send_assoc(); }
	g_sta_due = now + usb_us_to_ticks(STA_TIMEOUT_US);
}

fn void rtl_mgmt_rx(char* f, uint len, uint subtype)
{
	if (len < 24 || !rtl_mac_eq(&f[16], &g_sta_bssid[0])) { return; }
	if (subtype == 0xB0 && g_sta == STA_AUTH && len >= 30)
	{
		uint seq = (uint)f[26] | ((uint)f[27] << 8);
		uint st = (uint)f[28] | ((uint)f[29] << 8);
		if (seq != 2) { return; }
		if (st != 0)
		{
			print("wifi: auth refused, status ");
			print_uint(st);
			print("\n");
			g_sta_fail = st;
			g_sta = STA_IDLE;
			rtl_set_rx_promisc_beacons(true);
			return;
		}
		rtl_sta_step(STA_ASSOC);
	}
	else if (subtype == 0x10 && g_sta == STA_ASSOC && len >= 30)
	{
		uint st = (uint)f[26] | ((uint)f[27] << 8);
		if (st != 0)
		{
			print("wifi: association refused, status ");
			print_uint(st);
			print("\n");
			g_sta_fail = st;
			g_sta = STA_IDLE;
			rtl_set_rx_promisc_beacons(true);
			return;
		}
		g_sta_aid = ((uint)f[28] | ((uint)f[29] << 8)) & 0x3FFF;
		print("wifi: associated, aid ");
		print_uint(g_sta_aid);
		print("\n");
		if (g_sta_secure)
		{
			g_sta = STA_KEYS;
			g_wpa_mic_fail = 0;
			g_sta_due = rdtime() + usb_us_to_ticks(STA_KEYS_TIMEOUT_US);
			return;
		}
		g_sta = STA_UP;
		g_sta_rejoins = 0;
		rtl_link_set(true);
	}
	else if ((subtype == 0xC0 || subtype == 0xA0) && g_sta >= STA_AUTH && rtl_mac_eq(&f[4], &g_rtl_mac[0]) && len >= 26)
	{
		g_sta_reason = (uint)f[24] | ((uint)f[25] << 8);
		print("wifi: reason ");
		print_uint(g_sta_reason);
		print("\n");
		rtl_sta_lost(subtype == 0xC0 ? "deauthenticated" : "disassociated");
	}
}

// A data frame from the AP (FromDS) -> an Ethernet II frame to ipd.
fn void rtl_data_rx(char* f, uint len, bool hw_dec)
{
	if ((g_sta != STA_UP && g_sta != STA_KEYS) || !g_rtl_link_ok) { return; }
	uint fc0 = (uint)f[0];
	uint fc1 = (uint)f[1];
	if ((fc1 & 0x03) != 0x02) { return; }          // FromDS only
	if ((fc0 & 0x40) != 0) { return; }             // null / no-data subtypes
	if (!rtl_mac_eq(&f[10], &g_sta_bssid[0])) { return; }
	uint hdr = 24;
	if ((fc0 & 0x80) != 0) { hdr += 2; }           // QoS control
	if ((fc1 & 0x80) != 0) { hdr += 4; }           // HT control (order bit)
	bool prot = (fc1 & 0x40) != 0;
	if (prot)
	{
		// decrypted by the chip: drop the CCMP header and the MIC
		if (!hw_dec || !g_wpa_keyed || len < hdr + 8 + 8 + 8) { return; }
		hdr += 8;
		len -= 8;
	}
	if (len < hdr + 8) { return; }
	char* llc = &f[hdr];
	if ((uint)llc[0] != 0xAA || (uint)llc[1] != 0xAA || (uint)llc[2] != 0x03) { return; }
	uint etype = ((uint)llc[6] << 8) | (uint)llc[7];
	if (etype == 0x888E) { wpa_eapol_rx(&llc[8], len - hdr - 8); return; }
	if (g_sta != STA_UP || (g_sta_secure && !prot)) { return; }
	char* da = &f[4];
	char* sa = &f[16];
	if (rtl_mac_eq(sa, &g_rtl_mac[0])) { return; }  // our own broadcast, relayed back
	uint plen = len - hdr - 8;
	if (plen + 14 > LINK_FRAME_MAX) { return; }
	char[LINK_FRAME_MAX] e @noinit;
	put_mac(&e[0], da);
	put_mac(&e[6], sa);
	e[12] = llc[6];
	e[13] = llc[7];
	mem::copy(&e[14], &llc[8], (sz)plen);
	if (link_put(&g_rtl_link, &e[0], plen + 14)) { g_sta_rx_data++; }
}

fn void rtl_rx_frame(char* f, uint len, bool hw_dec)
{
	if (len < 24) { return; }
	uint fc0 = (uint)f[0];
	uint type = fc0 & 0x0C;
	if (type == 0x00) { rtl_mgmt_rx(f, len, fc0 & 0xF0); }
	else if (type == 0x08) { rtl_data_rx(f, len, hw_dec); }
}

// One 802.11 data frame to the AP (ToDS) carrying `payload` as ethertype
// `etype`: CCMP-protected (header here, encryption + MIC by the chip) once
// the keys are installed.
fn bool rtl_send_data(char* da, char* sa, uint etype, char* payload, uint plen)
{
	char[1600] f @noinit;
	if (plen + 40 > 1600) { return false; }
	f[0] = 0x08; f[1] = g_wpa_keyed ? 0x41 : 0x01; f[2] = 0; f[3] = 0;   // data, ToDS (+ protected)
	put_mac(&f[4], &g_sta_bssid[0]);
	put_mac(&f[10], sa);
	put_mac(&f[16], da);
	f[22] = 0; f[23] = 0;
	uint n = 24;
	if (g_wpa_keyed)
	{
		ulong pn = g_wpa_pn;
		g_wpa_pn++;
		f[24] = (char)pn; f[25] = (char)(pn >> 8); f[26] = 0; f[27] = 0x20;   // ExtIV, key id 0
		f[28] = (char)(pn >> 16); f[29] = (char)(pn >> 24); f[30] = (char)(pn >> 32); f[31] = (char)(pn >> 40);
		n = 32;
	}
	f[n] = 0xAA; f[n + 1] = 0xAA; f[n + 2] = 0x03; f[n + 3] = 0; f[n + 4] = 0; f[n + 5] = 0;
	f[n + 6] = (char)(etype >> 8); f[n + 7] = (char)etype;
	n += 8;
	mem::copy(&f[n], payload, (sz)plen);
	return rtl_tx(&f[0], n + plen, false, g_wpa_keyed);
}

// ipd's TX ring -> 802.11 data frames (ToDS) to the AP.
fn void rtl_data_tx_drain()
{
	if (!g_rtl_link_ok) { return; }
	char[LINK_FRAME_MAX] e @noinit;
	for (int k = 0; k < 8; k++)
	{
		int n = link_get(&g_rtl_link, &e[0]);
		if (n < 0) { break; }
		if (g_sta != STA_UP || n < 14) { continue; }
		uint etype = ((uint)e[12] << 8) | (uint)e[13];
		if (rtl_send_data(&e[0], &e[6], etype, &e[14], (uint)n - 14)) { g_sta_tx_data++; }
	}
}

// --- IPC from /bin/wifi (verbs routed here by usb_msc_ipc_poll) ----------

const uint WIFI_IPC_SCAN    = 40;   // start a scan (returns at once; ~3 s for 13 channels)
const uint WIFI_IPC_LIST    = 41;   // reply: the scan list as text
const uint WIFI_IPC_STATUS  = 42;   // reply: one status line
const uint WIFI_IPC_JOIN    = 43;   // req: NUL-terminated SSID; returns at once, joins in the background
const uint WIFI_IPC_LEAVE   = 44;   // deauth and drop the link

fn int rtl_hexval(char c)
{
	if (c >= '0' && c <= '9') { return c - '0'; }
	if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
	if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
	return -1;
}

// Boot-time join from /adm/wifi (written by `wifi save`): line 1 the
// SSID, line 2 empty (open network) or the PMK as 64 hex digits. A plain
// passphrase there is refused: PBKDF2 would stall usbd for seconds, so
// `wifi save` turns it into the PMK.
fn void rtl_autojoin()
{
	char[160] f;
	int n = fs_read("/adm/wifi", &f[0], 159);
	if (n <= 0) { return; }
	int a = 0;
	while (a < n && f[a] != '\n' && f[a] != '\r') { a++; }
	if (a == 0 || a > 32) { return; }
	for (int k = 0; k < a; k++) { g_sta_ssid[k] = f[k]; }
	g_sta_ssid[a] = 0;
	while (a < n && (f[a] == '\n' || f[a] == '\r')) { a++; }
	int b = a;
	while (b < n && f[b] != '\n' && f[b] != '\r') { b++; }
	g_wpa_have_pmk = false;
	if (b - a == 64)
	{
		bool ok = true;
		for (int i = 0; i < 32; i++)
		{
			int hi = rtl_hexval(f[a + 2 * i]);
			int lo = rtl_hexval(f[a + 2 * i + 1]);
			if (hi < 0 || lo < 0) { ok = false; break; }
			g_wpa_pmk[i] = (char)(hi * 16 + lo);
		}
		g_wpa_have_pmk = ok;
	}
	if (b > a && !g_wpa_have_pmk)
	{
		print("wifi: /adm/wifi line 2 isn't a 64-hex PMK — store it with `wifi save SSID PASSPHRASE`\n");
		return;
	}
	print("wifi: autojoin ");
	print(&g_sta_ssid[0]);
	print(" (/adm/wifi)\n");
	g_sta_fail = 0;
	g_sta_reason = 0;
	g_sta_rejoins = 0;
	rtl_join_start();
}

fn int rtl_cat(char* out, int n, char* s)
{
	for (int k = 0; s[k] != 0; k++) { out[n] = s[k]; n++; }
	return n;
}

fn void wifi_ipc(int from, uint verb, char* req)
{
	usb_set_split_context(false, 0, 0, false);
	char[4096] r;
	int n = 0;
	if (!g_rtl_present)
	{
		char* m = "wifi: no adapter\n";
		while (m[n] != 0) { r[4 + n] = m[n]; n++; }
	}
	else if (verb == WIFI_IPC_SCAN)
	{
		char* m = "scanning\n";
		if (g_sta != STA_IDLE) { m = "busy joining/joined — wifi leave first\n"; }
		else { rtl_scan_start(); }
		while (m[n] != 0) { r[4 + n] = m[n]; n++; }
	}
	else if (verb == WIFI_IPC_JOIN)
	{
		// [ssid, NUL-padded to 33][have_pmk][pmk 32]
		int k = 0;
		for (; k < 32 && req[k] != 0; k++) { g_sta_ssid[k] = req[k]; }
		g_sta_ssid[k] = 0;
		g_wpa_have_pmk = req[33] != 0;
		if (g_wpa_have_pmk) { mem::copy(&g_wpa_pmk[0], &req[34], 32); }
		g_sta_fail = 0;
		g_sta_reason = 0;
		g_sta_rejoins = 0;
		if (g_sta == STA_UP || g_sta == STA_KEYS) { rtl_send_deauth(); }
		rtl_join_start();
		char* m = g_sta == STA_IDLE ? "can't join (see dmesg)\n" : "joining\n";
		while (m[n] != 0) { r[4 + n] = m[n]; n++; }
	}
	else if (verb == WIFI_IPC_LEAVE)
	{
		if (g_sta == STA_UP || g_sta == STA_KEYS) { rtl_send_deauth(); }
		rtl_link_set(false);
		rtl_keys_clear();
		g_sta = STA_IDLE;
		rtl_set_rx_promisc_beacons(true);
		char* m = "left\n";
		while (m[n] != 0) { r[4 + n] = m[n]; n++; }
	}
	else if (verb == WIFI_IPC_LIST)
	{
		n = rtl_scan_text(&r[4], 4000);
	}
	else
	{
		char*[6] names = { "idle", "scanning", "authenticating", "associating", "associated", "handshaking" };
		char* m = names[g_sta];
		if (g_sta == STA_IDLE && g_rtl_scanning) { m = "scanning"; }
		n = rtl_cat(&r[4], n, m);
		if (g_sta != STA_IDLE)
		{
			n = rtl_cat(&r[4], n, " ssid ");
			n = rtl_cat(&r[4], n, &g_sta_ssid[0]);
		}
		n = rtl_cat(&r[4], n, " ch ");
		n += fmt::format_uint(g_rtl_channel, &r[4 + n]);
		n = rtl_cat(&r[4], n, " rx ");
		n += fmt::format_uint((uint)g_rtl_rx_frames, &r[4 + n]);
		n = rtl_cat(&r[4], n, " data rx/tx ");
		n += fmt::format_uint((uint)g_sta_rx_data, &r[4 + n]);
		n = rtl_cat(&r[4], n, "/");
		n += fmt::format_uint((uint)g_sta_tx_data, &r[4 + n]);
		if (g_sta == STA_UP) { n = rtl_cat(&r[4], n, g_wpa_keyed ? " wpa2" : " open"); }
		if (g_wpa_rekeys != 0)
		{
			n = rtl_cat(&r[4], n, " rekeys ");
			n += fmt::format_uint((uint)g_wpa_rekeys, &r[4 + n]);
		}
		if (g_sta_reason != 0)
		{
			n = rtl_cat(&r[4], n, " last deauth reason ");
			n += fmt::format_uint(g_sta_reason, &r[4 + n]);
		}
		if (g_sta_fail != 0)
		{
			n = rtl_cat(&r[4], n, " last refusal ");
			n += fmt::format_uint(g_sta_fail, &r[4 + n]);
		}
		r[4 + n] = '\n'; n++;
	}
	r[0] = (char)n; r[1] = (char)(n >> 8); r[2] = 0; r[3] = 0;
	ipc_reply(from, verb, &r[0], 4 + n, 0);
}
