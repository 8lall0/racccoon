/* config.h for TinyCC cross-built to riscv64-racccoon (roadmap §7.7).
 *
 * Hand-written in place of what tcc's ./configure emits — configure
 * assumes a hosted Linux/BSD/Windows target and gets the paths and the
 * OS-note machinery wrong for racccoon. Regenerate by hand if bumping
 * the vendored tcc: the only moving parts are TCC_VERSION and the two
 * GCC_* numbers (cosmetic — they feed tcc's __GNUC__ predefines).
 *
 * The block is gated `#if !(…RISCV64…)` exactly like configure's own
 * output, so scripts/build_tcc.sh must NOT also pass -DTCC_TARGET_RISCV64
 * on the command line (that would skip the CONFIG_TCC_* paths here).
 *
 * Deliberately absent vs. a stock config: CONFIG_OS_RELEASE (drags in
 * sscanf, only used for BSD notes) and CONFIG_TRIPLET (makes tcc hunt
 * for riscv64-linux-gnu/ subdirs we don't have).
 *
 * CONFIG_TCC_SWITCHES "-static": racccoon's kernel ELF loader maps
 * PT_LOAD segments only — no PT_INTERP, no dynamic relocation — so tcc
 * must emit a static executable. The load address is set by the
 * ELF_START_ADDR patch in lib/tcc/racccoon.patch (USER_BASE), not a
 * -Wl,-Ttext switch. */

#define TCC_VERSION "0.9.28rc"

#define CC_NAME CC_gcc
#define GCC_MAJOR 12
#define GCC_MINOR 2

#if !(TCC_TARGET_I386 || TCC_TARGET_X86_64 || TCC_TARGET_ARM \
   || TCC_TARGET_ARM64 || TCC_TARGET_RISCV64 || TCC_TARGET_C67)
#define TCC_TARGET_RISCV64 1
#define CONFIG_TCC_BACKTRACE 0
#define CONFIG_TCC_BCHECK 0
#define CONFIG_TCC_SYSINCLUDEPATHS "/lib/tcc/include:/include"
#define CONFIG_TCC_LIBPATHS "/lib/tcc:/lib"
#define CONFIG_TCC_CRTPREFIX "/lib/tcc"
#define CONFIG_TCC_ELFINTERP "-"
#define CONFIG_TCC_SWITCHES "-static"
#endif

#ifndef CONFIG_TCCDIR
#define CONFIG_TCCDIR "/lib/tcc"
#endif
#define CONFIG_TCC_PREDEFS 1
