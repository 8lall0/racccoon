extern "racccoon" fn print_i64(v: i64) void;
extern "racccoon" fn arg_count() i32;
extern "racccoon" fn arg(i: i32, ptr: [*]u8, cap: i32) i32;

fn parse_u32(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v * 10 + (c - '0');
    }
    return v;
}

export fn _start() void {
    var buf: [16]u8 = undefined;
    var n: u32 = 10;
    if (arg_count() > 0) {
        const w = arg(0, &buf, 16);
        if (w > 0) n = parse_u32(buf[0..@intCast(w)]);
    }
    var a: i64 = 0;
    var b: i64 = 1;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        const t = a + b;
        a = b;
        b = t;
    }
    print_i64(a);
}
