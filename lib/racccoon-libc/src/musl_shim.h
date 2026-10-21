/* Force-included (-include) when building musl's src/math with
 * racccoon-libc's headers: the two macros musl's own internal headers
 * would otherwise provide. */
#define hidden __attribute__((__visibility__("hidden")))
#define weak_alias(old, new) extern __typeof(old) new __attribute__((__weak__, __alias__(#old)))
