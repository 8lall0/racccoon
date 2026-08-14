module user;

fn void main() @export("main") {
    for (;;) {
        print("> ");

        char[128] cmdline @noinit;
        int i = 0;
        bool too_long = false;
        for (;;) {
            char ch = (char)getchar();
            putchar(ch);
            if (i == 127) {
                print("\ncommand line too long\n");
                too_long = true;
                break;
            }
            if (ch == '\r') {
                print("\n");
                cmdline[i] = 0;
                break;
            }
            cmdline[i] = ch;
            i++;
        }

        if (too_long) continue;

        char* cmd = &cmdline[0];
        if (strcmp(cmd, "hello") == 0) {
            print("Hello world from shell!\n");
        } else if (strcmp(cmd, "exit") == 0) {
            exit();
        } else {
            print("unknown command: ");
            print(cmd);
            print("\n");
        }
    }
}
