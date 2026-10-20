module user;

import std::io;

// dnsq name... — look names up through DNS (user.c3's dns_resolve, the
// server ipd got from DHCP) and print the IPv4 address.
fn void main(String[] args) {
    if (args.len == 0) { io::print("usage: dnsq name...\n"); exitcode(2); }
    int bad = 0;
    for (usz a = 0; a < args.len; a++) {
        uint ip;
        if (dns_resolve(args[a].ptr, &ip)) {
            char[20] t;
            net_fmt_ip(&t[0], ip);
            io::printfn("%s %s", (ZString)args[a].ptr, (ZString)&t[0]);
        } else {
            io::printfn("%s: not found", (ZString)args[a].ptr);
            bad++;
        }
    }
    if (bad > 0) { exitcode(1); }
}
