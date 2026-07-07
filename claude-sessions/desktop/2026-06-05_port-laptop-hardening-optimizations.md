# Port laptop optimizations + hardenings to the desktop (2026-06-05)

Bringing the ASUS-ROG-laptop ("helium") session work over to the desktop
("hydrogen", Ryzen 9 9950X / RTX 5090, OpenRC, ZFS root, SELinux permissive).
Source playbooks live under `claude-sessions/asus-rog-laptop/`. Done with three
parallel agents after reconciling each item against the desktop's *actual* live
state (several laptop assumptions about the desktop were stale).

## What was ALREADY present (no action)
- **`30-latency-scx.config`** (HZ_1000 + full PREEMPT + SCHED_CLASS_EXT + BTF)
  was already live in `/etc/kernel/config.d/`, and `sys-kernel/scx{,-loader}
  ~amd64` already in `package.accept_keywords/zz-autounmask`. NOTE: scx
  schedulers still can't *attach* because the desktop runs `confidentiality`
  lockdown (blocks BPF kernel writes) — pre-existing, unchanged.
- Hibernation already absent (`/sys/power/disk` missing); lockdown already
  `confidentiality`.

## Decisions (asked the user)
1. **Kernel rebuild = STAGE ONLY.** Remote/high-reboot-risk host, so the gcc-
   plugin + build-hardening fragments are staged; user runs the rebuild+reboot.
2. **Keep CONFIDENTIALITY.** The repo's `00-local-desktop.config` forces
   INTEGRITY — applying it would have *downgraded* this box. NOT applied; the
   live `00-local.config` (confidentiality) was left untouched.
3. **Apply ALL hardening sysctls now**, incl. the riskier two (io_uring off,
   one-way kexec latch).
4. **Keybindings: pending** — only the laptop lid-suspend toggle is documented
   (N/A on a desktop, no lid); user will paste their laptop keyd config to port
   the desktop-applicable parts.

## Changes made

### 1. Hardening sysctls — APPLIED LIVE
- Copied `other-backup-stuff/sysctl.d/99-hardening.conf` →
  `/etc/sysctl.d/99-hardening.conf` (regular-file convention, like
  `90-perf-tune.conf`), `sysctl --system`.
- **Conflict found & fixed:** pre-existing `99-local.conf` set
  `kernel.yama.ptrace_scope = 1` and sorts *after* `99-hardening.conf`, so it
  clobbered the hardened `= 2`. Removed that line from `99-local.conf` (live +
  `other-backup-stuff/` mirror), replaced with a pointer comment so the
  hardening file is the single owner of that knob. Re-applied.
- Live values now: `io_uring_disabled=2`, `kexec_load_disabled=1`
  (**one-way latch — engaged, cannot clear without reboot**), `ptrace_scope=2`,
  `bpf_jit_harden=2`, `sysrq=0`, `ldisc_autoload=0`.
- ⚠ `io_uring_disabled=2` is live while docker (ComfyUI/Open WebUI) runs — no
  observed disruption, but containers needing io_uring would feel it.

### 2. irqbalance — INSTALLED + ENABLED LIVE
- `emerge sys-apps/irqbalance` (1.9.5; pulled `sec-policy/selinux-irqbalance`).
  `rc-update add irqbalance default` + `rc-service irqbalance start`. Running.
- conf.d left stock (no banned CPUs, no oneshot). No AVC denials.

### 3. Kernel config — STAGED (no rebuild)
In `/etc/kernel/config.d/` (regular-file copies on this box, not symlinks):
- Removed stale `20-no-gcc-plugins.config`.
- Added `20-gcc-plugins.config` (GCC_PLUGINS=y, STACKLEAK, LATENT_ENTROPY,
  RANDSTRUCT pinned NONE) and `25-build-hardening.config` (ZERO_CALL_USED_REGS=y,
  LDISC_AUTOLOAD unset). Byte-identical to repo source.
- **`00-local.config` left as-is** (confidentiality preserved); `30-latency-scx`
  / `10-no-rust` untouched.

### 4. rc_parallel — STAGED (next boot)
- `/etc/rc.conf`: added active `rc_parallel="YES"` below the commented default.

## TO FINISH (user runs when ready)
```sh
emerge --oneshot sys-kernel/gentoo-kernel   # merges gcc-plugins + build-hardening
emerge @module-rebuild                       # rebuild zfs/nvidia vs new kernel
reboot                                        # rc_parallel also takes effect
```
Verify after reboot:
```sh
zcat /proc/config.gz | grep -E 'GCC_PLUGIN_STACKLEAK|GCC_PLUGIN_LATENT_ENTROPY|ZERO_CALL_USED_REGS|LDISC_AUTOLOAD'
cat /sys/kernel/security/lockdown        # still [confidentiality]
```

## Not committed
All `/etc/portage` working-tree edits (sysctl mirrors, kernel fragments) are
left UNCOMMITTED, matching house practice. `/etc/rc.conf`, `/etc/sysctl.d/*`,
runlevel state live outside the repo.

## Notes / gotchas
- Root's shell has `rm` aliased interactive (`rm -i`) — bare `rm` in an `&&`
  chain silently no-ops; use `rm -f`.
- `00-local-desktop.config` (repo) = INTEGRITY trap: do not symlink it here
  while the desktop intentionally runs confidentiality.
