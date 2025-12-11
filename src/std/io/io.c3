module std::io @if(env::CUSTOM_LIBC);
import libc;

fn bool File.isatty(File* self) {
    return false;
}

