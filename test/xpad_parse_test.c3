module user;

// Host-native unit test for user/usb/xpad.c3's xpad_parse_report() —
// pure byte-parsing logic, no USB/hardware I/O, so it can be checked
// on the dev machine without a real Duo or a real Xbox controller
// plugged in. Uses c3c's own built-in @test framework, run via
// `c3c compile-test test/xpad_parse_test.c3 user/usb/xpad.c3`
// (or bash scripts/test_xpad.sh).
//
// Expected values below are computed by hand from the documented wire
// format (see xpad.c3's own header comment and xpad_parse_report's
// comments), independently of the implementation under test — not by
// running the code and copying its output — so a real bug in the
// implementation (wrong byte offset, wrong bit, wrong NOT-vs-negate,
// etc.) will actually be caught.

fn void test_rejects_short_report() @test
{
    char[20] data;
    data[0] = (char)0x00;
    Xpad_state state;
    bool ok = xpad_parse_report(&data[0], 10, &state); // shorter than XPAD_REPORT_MIN_LEN (14)
    assert(ok == false, "short report should be rejected");
}

fn void test_rejects_non_input_report() @test
{
    char[20] data;
    data[0] = (char)0x01; // anything but 0x00 is not a controller-state report
    Xpad_state state;
    bool ok = xpad_parse_report(&data[0], 20, &state);
    assert(ok == false, "non-0x00 report byte should be rejected");
}

fn void test_single_button_and_sticks() @test
{
    char[20] data;
    data[0] = (char)0x00;
    data[1] = (char)0x14; // real report length byte — parser doesn't check it, but keep it realistic
    data[2] = (char)0x01; // dpad_up only
    data[3] = (char)0x10; // a only
    data[4] = (char)0x7F; // trigger_l = 127
    data[5] = (char)0xFF; // trigger_r = 255
    // stick_lx raw = 0x1234 (little-endian) -> positive, no NOT applied
    data[6] = (char)0x34;
    data[7] = (char)0x12;
    // stick_ly raw = 0x8000 before the driver's NOT -> ~0x8000 = 0x7FFF = 32767
    data[8] = (char)0x00;
    data[9] = (char)0x80;
    // stick_rx raw = 0xFFFF -> sign-extends to -1, no NOT applied
    data[10] = (char)0xFF;
    data[11] = (char)0xFF;
    // stick_ry raw = 0x0001 before NOT -> ~0x0001 = 0xFFFE = -2
    data[12] = (char)0x01;
    data[13] = (char)0x00;

    Xpad_state state;
    bool ok = xpad_parse_report(&data[0], 20, &state);
    assert(ok, "well-formed report should be accepted");

    assert(state.dpad_up, "dpad_up");
    assert(!state.dpad_down, "dpad_down");
    assert(!state.dpad_left, "dpad_left");
    assert(!state.dpad_right, "dpad_right");
    assert(!state.start, "start");
    assert(!state.back, "back");
    assert(!state.thumb_l, "thumb_l");
    assert(!state.thumb_r, "thumb_r");

    assert(!state.bumper_l, "bumper_l");
    assert(!state.bumper_r, "bumper_r");
    assert(!state.guide, "guide");
    assert(state.a, "a");
    assert(!state.b, "b");
    assert(!state.x, "x");
    assert(!state.y, "y");

    assert(state.trigger_l == 127, "trigger_l");
    assert(state.trigger_r == 255, "trigger_r");

    assert(state.stick_lx == 4660, "stick_lx");
    assert(state.stick_ly == 32767, "stick_ly");
    assert(state.stick_rx == -1, "stick_rx");
    assert(state.stick_ry == -2, "stick_ry");
}

fn void test_all_mapped_buttons_pressed() @test
{
    char[20] data;
    data[0] = (char)0x00;
    data[2] = (char)0xFF; // all 8 dpad/start/back/thumb bits
    data[3] = (char)0xF7; // all bumper/guide/a/b/x/y bits — bit 0x08 is unused/reserved, left clear on purpose

    Xpad_state state;
    bool ok = xpad_parse_report(&data[0], 20, &state);
    assert(ok, "well-formed report should be accepted");

    assert(state.dpad_up, "dpad_up");
    assert(state.dpad_down, "dpad_down");
    assert(state.dpad_left, "dpad_left");
    assert(state.dpad_right, "dpad_right");
    assert(state.start, "start");
    assert(state.back, "back");
    assert(state.thumb_l, "thumb_l");
    assert(state.thumb_r, "thumb_r");

    assert(state.bumper_l, "bumper_l");
    assert(state.bumper_r, "bumper_r");
    assert(state.guide, "guide");
    assert(state.a, "a");
    assert(state.b, "b");
    assert(state.x, "x");
    assert(state.y, "y");
}
