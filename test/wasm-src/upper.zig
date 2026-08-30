// Reads argv[0], upper-cases the ASCII letters, prints the result.
// Exercises: arg / print_str host imports, linear-memory read+write,
// a loop, i32 comparisons.
extern "racccoon" fn arg(i: i32, ptr: [*]u8, cap: i32) i32;
extern "racccoon" fn arg_count() i32;
extern "racccoon" fn print_str(ptr: [*]const u8, len: i32) void;

export fn _start() void {
    var buf: [128]u8 = undefined;
    if (arg_count() < 1) {
        const msg = "upper: needs an argument\n";
        print_str(msg, msg.len);
        return;
    }
    const n = arg(0, &buf, 127);
    if (n <= 0) return;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const c = buf[i];
        if (c >= 'a' and c <= 'z') buf[i] = c - 32;
    }
    buf[@intCast(n)] = '\n';
    print_str(&buf, n + 1);
}
