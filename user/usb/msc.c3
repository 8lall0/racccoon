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
// This file only implements enough of BOT + SCSI to prove real
// end-to-end I/O: TEST UNIT READY, INQUIRY, READ CAPACITY(10), and
// READ(10) — no WRITE support yet (deliberately out of scope until
// read-only access is confirmed working on real hardware first, per
// this project's own established habit of verifying each layer before
// building the next one on top of it).

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
fn void usb_enumerate_msc_device(uint dev_addr, uint max_packet0, char* config_buf, uint iface_num, uint num_endpoints, uint ep_start)
{
    uint ep_out_addr = 0;
    uint ep_in_addr = 0;
    uint ep_max_packet = 0;
    bool found_out = false;
    bool found_in = false;
    uint off = ep_start;
    for (uint i = 0; i < num_endpoints; i++)
    {
        uint b_length = (uint)config_buf[off] & 0xFF;
        if (b_length == 0) { break; }
        uint b_type = (uint)config_buf[off + 1] & 0xFF;
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
}
