module user;

import std::nolibc::mem;

// msc: USB Mass Storage Class, Bulk-Only Transport (BBB) — the "what
// this device class means" layer for user/usb/usbd.c3's own
// orchestration, same split as user/usb/xpad.c3 (device/class-
// specific byte formats) vs. user/usb/dwc2.c3 (generic USB host-
// controller transfers). Chosen as the next USB target specifically
// because bulk transfers don't carry the periodic-scheduling
// complexity (ODDFRM, MULTICNT, per-microframe NYET handling) that is
// still an open problem for this driver's own split interrupt
// transfers (docs/devlog.md) — CBW/CSW and SCSI command blocks below
// are sourced from the USB Mass Storage Class Bulk-Only Transport
// spec (USB-IF, rev 1.0) and the SCSI Primary/Block Commands specs,
// not guessed; the wire format was also cross-checked against a real
// captured usbmon trace of a live card reader's CBW/CSW exchange
// during this project's own investigation session.
//
// Implements enough of BOT + SCSI for real end-to-end I/O: TEST UNIT
// READY, INQUIRY, READ CAPACITY(10), READ(10), and WRITE(10). Also
// exposes the currently-attached device's raw sectors over IPC
// (usb_msc_ipc_poll(), called from usbd.c3's own main loop) — a single-
// sector-at-a-time protocol, same wire shape as diskd's own
// DISKD_READ/DISKD_WRITE (user/block/diskd.c3), for a standalone dd-
// style command to read/write a USB drive directly without the bigger
// step of wiring this into the fsd/mountable-filesystem layer (see
// docs/devlog.md for why that's a separate, larger piece of work).

const uint USB_MSC_CBW_SIGNATURE = 0x43425355; // "USBC", little-endian on the wire
const uint USB_MSC_CSW_SIGNATURE = 0x53425355; // "USBS", little-endian on the wire
const uint USB_MSC_CBW_LEN = 31;
const uint USB_MSC_CSW_LEN = 13;

const char USB_MSC_FLAG_DATA_IN  = (char)0x80;
const char USB_MSC_FLAG_DATA_OUT = (char)0x00;

const char USB_SCSI_TEST_UNIT_READY = (char)0x00;
const char USB_SCSI_INQUIRY         = (char)0x12;
const char USB_SCSI_READ_CAPACITY10 = (char)0x25;
const char USB_SCSI_READ10          = (char)0x28;
const char USB_SCSI_WRITE10         = (char)0x2A;

fn void write_le32(char* buf, uint offset, uint val)
{
    buf[offset]     = (char)(val & 0xFF);
    buf[offset + 1] = (char)((val >> 8) & 0xFF);
    buf[offset + 2] = (char)((val >> 16) & 0xFF);
    buf[offset + 3] = (char)((val >> 24) & 0xFF);
}

fn uint read_le32(char* buf, uint offset)
{
    return ((uint)buf[offset] & 0xFF)
        | (((uint)buf[offset + 1] & 0xFF) << 8)
        | (((uint)buf[offset + 2] & 0xFF) << 16)
        | (((uint)buf[offset + 3] & 0xFF) << 24);
}

fn uint read_be32(char* buf, uint offset)
{
    return (((uint)buf[offset] & 0xFF) << 24)
        | (((uint)buf[offset + 1] & 0xFF) << 16)
        | (((uint)buf[offset + 2] & 0xFF) << 8)
        | ((uint)buf[offset + 3] & 0xFF);
}

// Builds one 31-byte CBW into cbw_out. cb_len is the real SCSI command
// block's length (6 for TEST_UNIT_READY/INQUIRY, 10 for READ CAPACITY
// (10)/READ(10)); the CBWCB field is always 16 bytes on the wire,
// zero-padded past cb_len — BOT spec requires this padding even
// though most devices only look at the first cb_len bytes.
fn void msc_build_cbw(char* cbw_out, uint tag, uint data_len, bool data_in, char* cb, uint cb_len)
{
    mem::set(cbw_out, 0, USB_MSC_CBW_LEN);
    write_le32(cbw_out, 0, USB_MSC_CBW_SIGNATURE);
    write_le32(cbw_out, 4, tag);
    write_le32(cbw_out, 8, data_len);
    cbw_out[12] = data_in ? USB_MSC_FLAG_DATA_IN : USB_MSC_FLAG_DATA_OUT;
    cbw_out[13] = (char)0; // LUN 0 — every real device this driver targets exposes exactly one
    cbw_out[14] = (char)(cb_len & 0x1F);
    for (uint i = 0; i < cb_len && i < 16; i++)
    {
        cbw_out[15 + i] = cb[i];
    }
}

uint g_msc_tag = 1;

// One full BOT command/data/status cycle: CBW out, optional data
// stage (IN or OUT, only IN implemented — see this file's own top
// comment), CSW in. Returns false on any transport-level failure
// (a failed bulk transfer at any of the three stages) or if the CSW's
// own signature/tag don't match what was sent — both are "this
// exchange is no longer trustworthy" conditions, not something a
// caller should try to interpret further. *csw_status_out gets the
// real SCSI-level status byte (0 = command passed) whenever this
// returns true, so a caller can still distinguish "transport worked,
// but the device rejected the command" from a genuine transport
// failure.
fn bool msc_command(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in, char* cb, uint cb_len, void* data_buf, uint data_len, bool data_in, uint* csw_status_out)
{
    uint tag = g_msc_tag;
    g_msc_tag++;

    char[31] cbw;
    msc_build_cbw(&cbw[0], tag, data_len, data_in, cb, cb_len);

    uint actual_len;
    if (!usb_bulk_transfer(dev_addr, ep_out, max_packet, pid_out, false, &cbw[0], USB_MSC_CBW_LEN, &actual_len))
    {
        print("usbd: msc: CBW send failed\n");
        return false;
    }

    if (data_len > 0)
    {
        if (!usb_bulk_transfer(dev_addr, data_in ? ep_in : ep_out, max_packet, data_in ? pid_in : pid_out, data_in, data_buf, data_len, &actual_len))
        {
            print("usbd: msc: data stage failed\n");
            return false;
        }
    }

    char[13] csw;
    if (!usb_bulk_transfer(dev_addr, ep_in, max_packet, pid_in, true, &csw[0], USB_MSC_CSW_LEN, &actual_len))
    {
        print("usbd: msc: CSW read failed\n");
        return false;
    }

    if (actual_len < USB_MSC_CSW_LEN || read_le32(&csw[0], 0) != USB_MSC_CSW_SIGNATURE || read_le32(&csw[0], 4) != tag)
    {
        print("usbd: msc: CSW signature/tag mismatch\n");
        return false;
    }

    *csw_status_out = (uint)csw[12] & 0xFF;
    return true;
}

fn bool msc_test_unit_ready(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in)
{
    char[16] cb;
    mem::set(&cb[0], 0, 16);
    cb[0] = USB_SCSI_TEST_UNIT_READY;
    uint status;
    if (!msc_command(dev_addr, ep_out, ep_in, max_packet, pid_out, pid_in, &cb[0], 6, null, 0, true, &status)) { return false; }
    return status == 0;
}

fn bool msc_inquiry(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in, char* buf36)
{
    char[16] cb;
    mem::set(&cb[0], 0, 16);
    cb[0] = USB_SCSI_INQUIRY;
    cb[4] = (char)36; // allocation length — 36 bytes covers the fixed-format standard INQUIRY data every real device returns
    uint status;
    if (!msc_command(dev_addr, ep_out, ep_in, max_packet, pid_out, pid_in, &cb[0], 6, buf36, 36, true, &status)) { return false; }
    return status == 0;
}

// READ CAPACITY(10) returns 8 bytes: last valid LBA (big-endian
// uint32) followed by block size in bytes (big-endian uint32) — NOT
// total block count, an off-by-one every SCSI driver has to remember.
fn bool msc_read_capacity10(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in, uint* last_lba_out, uint* block_size_out)
{
    char[16] cb;
    mem::set(&cb[0], 0, 16);
    cb[0] = USB_SCSI_READ_CAPACITY10;
    char[8] buf;
    uint status;
    if (!msc_command(dev_addr, ep_out, ep_in, max_packet, pid_out, pid_in, &cb[0], 10, &buf[0], 8, true, &status)) { return false; }
    if (status != 0) { return false; }
    *last_lba_out = read_be32(&buf[0], 0);
    *block_size_out = read_be32(&buf[0], 4);
    return true;
}

// READ(10): reads num_blocks * block_size bytes starting at lba into
// buf. Caller owns buf's sizing — this driver's own DMA bounce buffer
// (usb_dma_paddr) is small, so real reads here go through the same
// max_packet-sized chunking as every other bulk transfer, just with a
// larger overall data_len; num_blocks is expected to stay small
// (single-sector probes) until a real block-device layer is built on
// top of this.
fn bool msc_read10(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in, uint lba, uint num_blocks, uint block_size, void* buf)
{
    char[16] cb;
    mem::set(&cb[0], 0, 16);
    cb[0] = USB_SCSI_READ10;
    cb[2] = (char)((lba >> 24) & 0xFF);
    cb[3] = (char)((lba >> 16) & 0xFF);
    cb[4] = (char)((lba >> 8) & 0xFF);
    cb[5] = (char)(lba & 0xFF);
    cb[7] = (char)((num_blocks >> 8) & 0xFF);
    cb[8] = (char)(num_blocks & 0xFF);
    uint status;
    if (!msc_command(dev_addr, ep_out, ep_in, max_packet, pid_out, pid_in, &cb[0], 10, buf, num_blocks * block_size, true, &status)) { return false; }
    return status == 0;
}

// WRITE(10) — same CDB layout as READ10 above, opcode 0x2A, data stage
// direction OUT instead of IN. msc_command() already supports an OUT
// data stage generically (data_in=false copies buf to the device before
// the CSW), so this is the only new piece needed.
fn bool msc_write10(uint dev_addr, uint ep_out, uint ep_in, uint max_packet, uint* pid_out, uint* pid_in, uint lba, uint num_blocks, uint block_size, void* buf)
{
    char[16] cb;
    mem::set(&cb[0], 0, 16);
    cb[0] = USB_SCSI_WRITE10;
    cb[2] = (char)((lba >> 24) & 0xFF);
    cb[3] = (char)((lba >> 16) & 0xFF);
    cb[4] = (char)((lba >> 8) & 0xFF);
    cb[5] = (char)(lba & 0xFF);
    cb[7] = (char)((num_blocks >> 8) & 0xFF);
    cb[8] = (char)(num_blocks & 0xFF);
    uint status;
    if (!msc_command(dev_addr, ep_out, ep_in, max_packet, pid_out, pid_in, &cb[0], 10, buf, num_blocks * block_size, false, &status)) { return false; }
    return status == 0;
}

// --- Raw-sector IPC responder: exposes the currently-attached MSC
// device's own sectors to any other process (a standalone dd-style
// command, user/bin/usbrw.c3) via the same 516-byte wire shape as
// diskd's own protocol — byte 0..3 = sector number, byte 4..515 = one
// 512-byte sector's data. Session state (endpoints, toggles, geometry)
// persists here across calls, set once when a device is found
// (usb_enumerate_msc_device below) and cleared on disconnect
// (usb_msc_clear_session(), called from usbd.c3's own hub-port
// hot-plug/disconnect handling).
//
// Deliberately its own small protocol, not wired into fsd/the
// diskd_rw()-consuming filesystem layer at all — that would need fsd
// itself to support a dynamically-discovered backend instead of its own
// hardcoded DISKD_PID, plus a way to spawn/mount a new instance at
// runtime when a drive shows up, a materially bigger piece of work than
// proving raw read/write actually works on real hardware first (see
// docs/devlog.md).
const uint USB_MSC_IPC_READ  = 100; // arbitrary, just needs to not collide with anything else usbd's own single inbox ever receives — it currently receives nothing else at all
const uint USB_MSC_IPC_WRITE = 101;
const uint USB_MSC_IPC_MSG_MAX = 516; // 4 (sector) + 512 (one block) — same shape as diskd's own DISKD_MSG_MAX

bool g_msc_present = false;
uint g_msc_hub_port = 0;
uint g_msc_dev_addr = 0;
uint g_msc_ep_out = 0;
uint g_msc_ep_in = 0;
uint g_msc_max_packet = 0;
uint g_msc_pid_out = 0;
uint g_msc_pid_in = 0;
uint g_msc_block_size = 0;
uint g_msc_last_lba = 0;

// Called from usbd.c3's own usb_poll_hub_ports() when the hub port
// holding the current MSC device (if any) goes empty — see
// g_msc_hub_port's own comment. Safe to call unconditionally even if no
// device is attached (or a different port disconnected).
fn void usb_msc_clear_session(uint disconnected_port)
{
    if (g_msc_present && disconnected_port == g_msc_hub_port)
    {
        g_msc_present = false;
    }
}

// Non-blocking — see hc_transfer_once_split's own convention for the
// wider "poll, don't block" reasoning that applies here too: usbd's
// main loop still needs to keep servicing HPRT0/hub-port polling
// regardless of whether a block-IO client ever sends anything.
// Requires g_msc_block_size == 512 (true for essentially every real USB
// flash drive/card reader — the wire protocol here is fixed at one
// 512-byte sector per request, matching diskd's own SECTOR_SIZE, not a
// general variable-block-size design); a device with a different real
// block size is left attached but unreachable through this specific
// protocol, cleanly rejected below rather than silently corrupting data
// with a mismatched size.
fn void usb_msc_ipc_poll()
{
    char[USB_MSC_IPC_MSG_MAX] buf @noinit;
    uint verb = 0;
    int from = ipc_poll_type(&buf[0], USB_MSC_IPC_MSG_MAX, &verb);
    if (from < 0) { return; }
    if (verb != USB_MSC_IPC_READ && verb != USB_MSC_IPC_WRITE) { return; }

    bool is_write = verb == USB_MSC_IPC_WRITE;
    uint* sector_field = (uint*)&buf[0];
    uint lba = *sector_field;

    bool ok = false;
    if (g_msc_present && g_msc_block_size == 512 && lba <= g_msc_last_lba)
    {
        if (is_write)
        {
            ok = msc_write10(g_msc_dev_addr, g_msc_ep_out, g_msc_ep_in, g_msc_max_packet, &g_msc_pid_out, &g_msc_pid_in, lba, 1, 512, &buf[4]);
        }
        else
        {
            ok = msc_read10(g_msc_dev_addr, g_msc_ep_out, g_msc_ep_in, g_msc_max_packet, &g_msc_pid_out, &g_msc_pid_in, lba, 1, 512, &buf[4]);
        }
    }

    buf[0] = ok ? (char)0 : (char)1;
    ipc_reply(from, verb, &buf[0], USB_MSC_IPC_MSG_MAX, 0);
}

// Entry point called from usbd.c3's own class-dispatch once a mass
// storage interface has been found and SET_CONFIGURATION has already
// run. Walks the interface's own endpoint descriptors for the bulk IN
// and bulk OUT pair every BOT device exposes (exactly 2 endpoints,
// no interrupt endpoint — unlike CBI, obsolete and unimplemented
// here), then runs a one-shot TEST UNIT READY / INQUIRY / READ
// CAPACITY(10) probe to confirm the transport actually works
// end-to-end on real hardware. No persistent read loop yet (unlike
// xpad's own usbd_xpad_read_loop) — this is deliberately a proof-of-
// transport probe per the current phase's own scope ("preparation for
// usb mass storage, then we can test it later"), not a full block
// device driver.
fn void usb_enumerate_msc_device(uint dev_addr, uint max_packet0, char* config_buf, uint iface_num, uint num_endpoints, uint ep_start, uint hub_port)
{
    uint ep_out_addr = 0;
    uint ep_in_addr = 0;
    uint ep_max_packet = 0;
    bool found_out = false;
    bool found_in = false;
    // Walks by real endpoint COUNT, not raw descriptor position — see
    // usbd.c3's own endpoint-walk comment (usb_enumerate_hub_port_device)
    // for the real bug this exact shape fixes on a different device
    // class (an interleaved non-endpoint descriptor silently consuming
    // one of the num_endpoints iterations). Applied here defensively —
    // no real device has shown this specific problem for MSC yet — for
    // the same reason, not because it's been observed to matter.
    uint off = ep_start;
    uint endpoints_found = 0;
    while (off + 1 < 256 && endpoints_found < num_endpoints)
    {
        uint b_length = (uint)config_buf[off] & 0xFF;
        if (b_length == 0) { break; }
        uint b_type = (uint)config_buf[off + 1] & 0xFF;
        if (b_type == USB_DESC_TYPE_INTERFACE) { break; }
        if (b_type == USB_DESC_TYPE_ENDPOINT)
        {
            char* ep_desc = &config_buf[off];
            uint addr = usb_ep_desc_address(ep_desc);
            uint xfer_type = usb_ep_desc_xfer_type(ep_desc);
            if (xfer_type == USB_EP_XFERTYPE_BULK)
            {
                if ((addr & 0x80) != 0)
                {
                    ep_in_addr = addr;
                    found_in = true;
                }
                else
                {
                    ep_out_addr = addr;
                    found_out = true;
                }
                ep_max_packet = usb_ep_desc_max_packet(ep_desc);
            }
            endpoints_found++;
        }
        off += b_length;
    }

    if (!found_in || !found_out)
    {
        print("usbd: msc: bulk IN/OUT endpoint pair not found\n");
        return;
    }

    print("usbd: msc: device found, interface ");
    print_uint(iface_num);
    print(", bulk OUT 0x");
    print_hex8(ep_out_addr);
    print(", bulk IN 0x");
    print_hex8(ep_in_addr);
    print("\n");

    uint ep_out = ep_out_addr & 0x0F;
    uint ep_in = ep_in_addr & 0x0F;
    // Bulk endpoints reset their DATA toggle to DATA0 on
    // SET_CONFIGURATION (USB 2.0 spec 9.1.1.5/5.8.4) — already just
    // ran in usbd.c3 right before this function was called.
    uint pid_out = USB_PID_DATA0;
    uint pid_in = USB_PID_DATA0;

    if (!msc_test_unit_ready(dev_addr, ep_out, ep_in, ep_max_packet, &pid_out, &pid_in))
    {
        print("usbd: msc: TEST UNIT READY failed (or reported not-ready)\n");
        return;
    }
    print("usbd: msc: TEST UNIT READY passed\n");

    char[36] inquiry_buf;
    if (!msc_inquiry(dev_addr, ep_out, ep_in, ep_max_packet, &pid_out, &pid_in, &inquiry_buf[0]))
    {
        print("usbd: msc: INQUIRY failed\n");
        return;
    }
    print("usbd: msc: INQUIRY vendor=\"");
    for (uint i = 0; i < 8; i++) { putchar(inquiry_buf[8 + i]); }
    print("\" product=\"");
    for (uint i = 0; i < 16; i++) { putchar(inquiry_buf[16 + i]); }
    print("\"\n");

    uint last_lba;
    uint block_size;
    if (!msc_read_capacity10(dev_addr, ep_out, ep_in, ep_max_packet, &pid_out, &pid_in, &last_lba, &block_size))
    {
        print("usbd: msc: READ CAPACITY(10) failed\n");
        return;
    }
    print("usbd: msc: capacity: ");
    print_uint(last_lba + 1);
    print(" blocks x ");
    print_uint(block_size);
    print(" bytes\n");

    char[512] sector0;
    if (block_size > 0 && block_size <= 512 && msc_read10(dev_addr, ep_out, ep_in, ep_max_packet, &pid_out, &pid_in, 0, 1, block_size, &sector0[0]))
    {
        print("usbd: msc: READ(10) of LBA 0 succeeded, first bytes: ");
        for (uint i = 0; i < 16; i++)
        {
            putchar(' ');
            print_hex8((uint)sector0[i] & 0xFF);
        }
        print("\n");
    }
    else
    {
        print("usbd: msc: READ(10) of LBA 0 failed or block size unsupported\n");
    }

    // Persist this session for usb_msc_ipc_poll() — after every local
    // diagnostic transfer above, so pid_out/pid_in reflect the real,
    // hardware-advanced toggle state at this point, not a stale
    // snapshot from before the READ(10) demo just above also advanced
    // it. See that function's own comment for the wire protocol and why
    // it's fixed at 512-byte sectors regardless of what this device's
    // own real block_size turns out to be.
    g_msc_dev_addr = dev_addr;
    g_msc_ep_out = ep_out;
    g_msc_ep_in = ep_in;
    g_msc_max_packet = ep_max_packet;
    g_msc_pid_out = pid_out;
    g_msc_pid_in = pid_in;
    g_msc_block_size = block_size;
    g_msc_last_lba = last_lba;
    g_msc_hub_port = hub_port;
    g_msc_present = true;
    if (block_size != 512)
    {
        print("usbd: msc: block size is ");
        print_uint(block_size);
        print(", not 512 — raw sector IPC (usbrw) won't work correctly against this device\n");
    }
}
