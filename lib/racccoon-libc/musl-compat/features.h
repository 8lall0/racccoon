/* Empty stand-in for musl's <features.h>, which a few of musl's src/math
 * headers include for `hidden` — src/musl_shim.h already defines it.
 * Only on the include path while building musl's libm (build.sh). */
