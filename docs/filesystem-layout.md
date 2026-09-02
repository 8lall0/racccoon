# Filesystem layout

The canonical root tree. Plan 9-flavoured — see `docs/roadmap.md` §1.

```
/               ext2, the root on every board
/bin            executables — exec() reads them off the fs, they are not
                embedded in the kernel image the way the servers are
/lib            shared data: wasm modules, fixtures, anything exec-adjacent
/usr            per-user home directories
/usr/root       root's home (§2 adds real users: /usr/glenda, …)
/usr/$user/bin  the user's own binaries — `bind -ac`'d onto /bin at
                login, so a self-built program runs by bare name without
                /bin itself being writable (docs/bin-layout.md)
/adm            host administration
/adm/users      the user database (§2) — "uid:name" lines, one per user
/tmp            scratch
/mnt            where other filesystems / services get mounted
lost+found      ext2's own
```

**Not real directories** — these are per-process *namespace mounts*
(`src/process.c3`'s `create_process` seeds them), resolved by prefix
before any on-disk directory is consulted:

```
/proc/          procd     — process control (SYS_PROC_INFO, kill via ctl)
/srv/           posted server connections (/srv/echo/ → echod today)
/env/           envd      — per-process environment variables
/mnt/fs2/       the second fsd instance (dual-partition test setups)
```

No `/dev` — devices are servers (`usbd`, `sdd`, …), reached by name or a
mount, not device nodes. No `/etc` — host config lives in `/adm`,
per-user config under `/usr/$user/lib`.

## Where it's created

- **QEMU images** — `scripts/build.sh` seeds it into `disk_ext2.img`
  and `disk_dual_root_part.img` via `debugfs`.
- **Real Duo** — `sudo DUO_ROOT_PARTITION=/dev/sdX2 bash
  scripts/populate_duo_bin.sh` creates it (and `/bin`'s contents) on the
  mounted ext2 partition. `scripts/provision_duo_sd.sh` formats the
  partition; this fills it.

The directory list is duplicated between those two scripts and kept in
sync by hand — same convention as the `/bin` binary list.
