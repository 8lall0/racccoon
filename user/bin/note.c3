module user;

import std::io;

// note [-g] <pid> [msg] — post a note (src/note.c3, Plan 9's signals) to
// process <pid>, or with -g to every process in note group <pid>. msg
// defaults to "interrupt" (what ^C sends); "kill" always kills. A process
// with no note handler dies of any note. Root, or the target's own uid.
fn void main(String[] args) {
    bool group = args.len > 0 && args[0].len == 2 && args[0][0] == '-' && args[0][1] == 'g';
    int a = group ? 1 : 0;
    if (args.len - a < 1 || args.len - a > 2) {
        io::print("usage: note [-g] <pid> [msg]\n");
        return;
    }
    int? id = args[a].to_int();
    if (catch id) {
        io::print("note: bad pid\n");
        return;
    }
    char* msg = args.len - a == 2 ? args[a + 1].ptr : "interrupt";
    int r = group ? postnote_group(id, msg) : postnote(id, msg);
    if (r < 0) {
        io::print("note: no such process, or not allowed\n");
        exitcode(1);
    }
}
