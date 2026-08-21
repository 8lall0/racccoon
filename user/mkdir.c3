module user;

// Real, argv-taking replacement for shell.c3's own former mkdirtest
// (hardcoded to a fixed path).
fn void main() @export("main") {
    char** argv;
    int argc = get_argv(&argv);
    if (argc != 1) {
        print("usage: mkdir <path>\n");
        return;
    }

    int result = fs_mkdir(argv[0]);
    if (result < 0) {
        print("mkdir: ");
        print(argv[0]);
        print(": failed\n");
    }
}
