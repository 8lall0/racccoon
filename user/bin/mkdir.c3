module user;

import std::io;

// Real, argv-taking replacement for shell.c3's own former mkdirtest
// (hardcoded to a fixed path).
fn void main(String[] args) {
    if (args.len != 1) {
        io::print("usage: mkdir <path>\n");
        return;
    }

    int result = fs_mkdir(args[0].ptr);
    if (result < 0) {
        io::print("mkdir: ");
        io::print((ZString)args[0].ptr);
        io::print(": failed\n");
    }
}
