module std::io @if(env::CUSTOM_LIBC);

fn bool File.isatty(File* self) {
    return false;
}