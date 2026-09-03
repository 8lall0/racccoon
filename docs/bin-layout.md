# Binary directory layout

How executables are named, where they live, and how a bare command name
resolves. Plan 9-derived — but adapted to what racccoon actually is: a
single-architecture system with an on-device toolchain.

## Decisions

### 1. No architecture directory

Plan 9 keeps `/386`, `/amd64`, `/arm`, `/power` at the root, each with
its own `bin`, `lib`, … so one central file server can serve a network
of machines of different CPU types (`bind /$cputype/bin /bin` at login
picks the right set).

racccoon has no such need:

- Both supported boards — Milk-V Duo (CV1800B) and Orange Pi RV
  (JH7110) — are **riscv64**. So is every third target on the radar.
- Each board boots its own SD card; there is no shared multi-arch
  rootfs.
- The on-device toolchains (tcc, `go`, c3c-to-come) all emit riscv64.

An `/riscv64/bin` would therefore be a one-element set forever, adding a
level of indirection for zero benefit. **`/bin` is flat.**

The name `/riscv64` is *reserved* — documented here, not created. If a
non-riscv64 target ever lands on a rootfs that must also serve riscv64,
the migration is: `mkdir /riscv64`, move the tree, `bind /riscv64/bin
/bin` in the boot profile. Until then, don't build the layer.

### 2. `/bin` is the whole search path

There is no `$PATH`. The shell resolves a bare name (`ls`) by prepending
`/bin/`; a name containing `/` (`./foo`, `/bin/foo`, `sub/foo`) is taken
literally, cwd-relative unless it starts with `/`. This is already how
`shell_spawn` (`user/shell_common.c3`) works and it is exactly the Plan
9 model — `/bin` *is* the namespace, not one entry in a list.

### 2a. No `/sbin`

Plan 9 has none, and neither does racccoon. There is no "privileged
binary" directory. A tool is privileged only because of the checks it
hits when it runs — `SYS_KILL` wants root-or-same-uid, `fsd` enforces
file ownership, raw device MMIO is handed only to the boot servers,
`SYS_SETUID` only ever drops. `/sbin` in Unix is a historical
statically-linked-for-early-boot convention, not a security boundary
(anyone can run `/sbin/ifconfig`; it just fails without privilege).

If we ever want "the hostowner sees extra admin tools," that is a
*union* expressed per-profile — `bind -a /adm/bin /bin` in the
hostowner's login only — not a directory everyone can see but only root
can use. The mechanism in §5 already covers it.

### 3. System binaries: `/bin`, root-owned, immutable in practice

The seeded set — `cat ls echo … tcc go go-compile go-link wasm fsd …` —
lives directly in `/bin`, owned by uid 0. Written only by the image
build (`scripts/build.sh`) / provisioning (`scripts/populate_duo_bin.sh`).
Nothing at runtime writes here *directly* — but see §4/§5: a create
under `/bin` is routed by the union to the caller's own bin dir.

### 4. User-built binaries: `/usr/$user/bin`

The idiom is **`-o /bin/<name>`**: `tcc hello.c -o /bin/hello`,
`go build -o /bin/hello`, `go-link -o /bin/hello`. The `/bin` union's
create member (§5) sends the new file to `/usr/$user/bin/hello`, so it
runs as `hello` immediately — without `/bin` itself being writable, and
without the toolchain needing any racccoon-specific `-o` magic (a bare
`-o hello` still writes `./hello`, standard Unix). `/usr/$user/bin` is
seeded per user alongside the home directory. An absolute `-o
/some/other/path` is honoured verbatim.

Every fs client resolves a create through the union: `user/user.c3`
(`fs_write` etc.), `lib/racccoon-libc/src/rc_fs.c`, and
`go/goos/racccoon_fs.go` all use `ns_translate(path, -1, …)` — member
`-1` = "the create member" (`ns_translate_core`, `src/entry.c3`).

### 5. `/bin` is a union; `/usr/$user/bin` unions in at login

So a just-built `hello` runs as `hello`, no path, without making `/bin`
world-writable:

```
# boot profile / shell_login, after the user's identity is known:
bind -a /usr/$user/bin /bin
```

`bind -a` adds `/usr/$user/bin` as a *second* source for the mount point
`/bin`, searched after the physical `/bin`. Lookups try each member in
order; `FS_LIST` merges the members (first occurrence of a name wins);
`create` lands in the first writable member (so a user can't be
tricked into shadowing a system binary — their layer is below).

`/lib` could union the same way (`bind -a /usr/$user/lib /lib`) but is
not wired until something needs it.

## Namespace mechanics this requires

Today a `Mount` (`src/process.c3`) is `{ prefix, server_pid,
generation }` — longest-prefix match, one server per prefix. `bind`
(`SYS_NS_BIND`) can only repoint a prefix at a *different server*; it
can't alias paths within one file server, and there is no unioning.

Two additions:

- **Path rewriting.** `Mount` gains a target prefix. On resolve, a path
  under a rewriting bind has its bound prefix replaced by the target
  before the server sees it: with `bind /X /bin`, `/bin/foo` → `/X/foo`.
  This alone makes `bind` a real aliasing primitive (`bind /mnt/sd/media
  /media`, …), independent of unions.
- **Union list.** A mount point holds an ordered list of members rather
  than a single binding. `SYS_NS_RESOLVE` returns the list; the client
  (or a kernel helper) walks it for `open`/`stat`, and `fsd` merges for
  `FS_LIST`. `bind` replaces, `bind -a` appends (after), `bind -b`
  prepends (before) — Plan 9's flags.

## Where the tree is seeded

Unchanged from `docs/filesystem-layout.md`: `scripts/build.sh` for the
QEMU images, `scripts/populate_duo_bin.sh` for the real Duo, kept in
sync by hand. This doc adds `/usr/$user/bin` to both directory lists.
