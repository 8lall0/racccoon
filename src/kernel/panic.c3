module panic;

import std::io;

macro panic(String msg) {
    io::printfn("PANIC: %s - %s:%d\n", msg, $$FILE, $$LINE);
    for(;;) {
        asm {
            wfi;
        }
    }
}