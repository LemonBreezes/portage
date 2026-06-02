# Kernel + sysctl hardening: full lockdown, hibernation removal, GCC plugins

**Date:** 2026-06-01
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop)
**Goal:** Raise the laptop's exploit-mitigation posture: maximum kernel
lockdown, remove hibernation, re-enable GCC-plugin self-protection, and add
attack-surface sysctls — all on the existing `gentoo-kernel[hardened]` +
SELinux + module-sign + ZFS-root stack, no kernel version change.

## Headline decision: stay on 6.18, NOT kernel 7

The session started aiming at `gentoo-kernel-7.0.x`, gated behind accepting
`zfs-kmod-2.4.0_rc2`. Investigation killed that path:

- `sys-fs/zfs-kmod-2.4.0_rc2-r1` is a **12-line stub** (`RDEPEND=">=sys-fs/zfs-2.4.0_rc2-r1"`,
  no `inherit`, no module build). In the 2.4.x era the module build moved into
  `sys-fs/zfs` itself; `-kmod` is now a compat shim.
- The real cap lives in userland `sys-fs/zfs`, and **every** available version
  still caps `MODULES_KERNEL_MAX` ≤ 6.19: `zfs-2.4.0`→6.18, `zfs-2.4.1`→6.19,
  even `zfs-9999` (git)→6.19. Kernel 7.0 (major 7 > 6) dies in `pkg_setup`
  ("Linux 6.19 is the latest supported version").
- There is no `gentoo-kernel-6.19` in the tree either (6.18 → 7.0 directly).

So kernel 7 is **unbuildable on a ZFS root** right now. The existing
`package.mask/main` entry (`>=sys-kernel/gentoo-kernel-7`, …) was already
correct and was **left in place**; its own note — "Drop the mask when sys-fs/zfs
ships an ebuild that supports kernel 7.x" — is the trigger to revisit. The
`zfs-kmod-2.4.0_rc2-r1 **` keyword that was briefly added to `zz-autounmask`
was **reverted** (it unlocked nothing and would only drag root-pool userland
2.3.6→2.4.1 for no benefit). ZFS stays at stable **2.3.6**.

All hardening below therefore targets the current **`gentoo-kernel-6.18.33_p1`**,
applied via a same-version rebuild (config-only change).

## Changes made (config only — rebuild was kicked off at end of session)

### 1. Full kernel lockdown + hibernation removal
**File:** `other-backup-stuff/kernel/config.d/00-local-laptop.config`
- `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE` → **`CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY=y`**
  (was NONE to allow hibernation; hibernation is now gone, so the max tier is
  on the table). Confidentiality adds, over INTEGRITY: no `/proc/kcore`, no
  `/proc/kallsyms` addresses, no `perf` kernel sampling, **no BPF reads of
  kernel memory** — the last closes the "root dumps the live ZFS key from
  kernel RAM" path.
- Hibernation removed: `# CONFIG_HIBERNATION is not set` made explicit
  (confidentiality blocks it at runtime anyway; we also compile out swsusp).

**`resume=` purge (hibernation leftover, 3 places):**
- `other-backup-stuff/kernel/cmdline` (git source of truth; `/etc/kernel/cmdline`
  symlinks to it) — dropped `resume=UUID=7f0c…`.
- ZFSBootMenu property: `zfs set org.zfsbootmenu:commandline=…` on
  `rpool/ROOT/gentoo` (what ZBM actually boots from) — dropped `resume=` live.

**Dracut:** renamed `/etc/dracut.conf.d/hibernate.conf` →
`90-encrypted-swap.conf` (NOT in the /etc/portage repo). Dropped the `resume`
module; **kept** `crypt` + the swap keyfile embed + `crypttab.initramfs` —
swap is defined ONLY there, so removing it would have killed encrypted swap.
Fixed the now-stale hibernation comment in `/etc/crypttab.initramfs`.

### 2. GCC plugins RE-ENABLED (the stale-disable correction)
**File:** `other-backup-stuff/kernel/config.d/20-gcc-plugins.config`
(replaces `20-no-gcc-plugins.config`; symlink swapped in `/etc/kernel/config.d/`).

The old fragment disabled `CONFIG_GCC_PLUGINS` claiming gcc-16 couldn't compile
`scripts/gcc-plugins/*.c` (CONST_CAST_TREE / irange ABI). **Re-tested and
disproved**: compiled `latent_entropy_plugin.c` and `stackleak_plugin.c`
against the live 6.18 source under gcc-16.1.0 — both build cleanly. The only
failure was forcing the obsolete `-std=gnu++11`; the kernel's plugin build uses
gcc-16's default **gnu++17** (top Makefile sets no `-std` for HOSTCXX). The
blanket disable was stale.
- `CONFIG_GCC_PLUGINS=y`
- `CONFIG_GCC_PLUGIN_STACKLEAK=y` (erase kernel stack on return-to-userspace)
- `CONFIG_GCC_PLUGIN_LATENT_ENTROPY=y` (what the hardened distconfig had before)
- **RANDSTRUCT pinned OFF**: `CONFIG_RANDSTRUCT_NONE=y` (+ FULL/PERFORMANCE not
  set). Pinned explicitly so the hardened distconfig can't silently select
  FULL now that plugins are back. Deferred because RANDSTRUCT_FULL's per-build
  seed forces ZFS (root) rebuilt in lockstep on every kernel build — too risky
  to add in the same step. Flip later in isolation.

### 3. Compiler-feature self-protection (not plugins)
**File:** `other-backup-stuff/kernel/config.d/25-build-hardening.config` (new, symlinked)
- `CONFIG_ZERO_CALL_USED_REGS=y` (zero call-clobbered regs on return; gcc-16
  supports `-fzero-call-used-regs`, `CC_HAS_…=y` verified).
- `# CONFIG_LDISC_AUTOLOAD is not set` (compile-time twin of the sysctl below).
- `UBSAN_TRAP` deliberately **NOT** enabled (would panic on a UBSAN false
  positive; `UBSAN_BOUNDS_STRICT=y` already logs OOB). Revisit later.

### 4. Attack-surface sysctls
**File:** `other-backup-stuff/sysctl.d/99-hardening.conf` (symlinked to
`/etc/sysctl.d/99-hardening.conf`, matching `90-perf-tune.conf`). **Not applied
live yet** (`sysctl --system` on next boot, or run manually):
- `kernel.io_uring_disabled = 2`
- `dev.tty.ldisc_autoload = 0`
- `kernel.kexec_load_disabled = 1` — ⚠ **one-way latch**; disables **ALL**
  kexec (the shared `kexec_load_permitted()` helper gates both `kexec_load()`
  AND signed `kexec_file_load()` — it is NOT selective to the legacy call).
  Safe here: no `crashkernel=` (kdump off), the OpenRC `kexec` service isn't
  enabled, and ZBM kexecs from its own kernel. The misleading "you use signed
  kexec_file" comment was corrected in the file.
- `kernel.yama.ptrace_scope = 2`  (admin-only ptrace)
- `net.core.bpf_jit_harden = 2`
- `kernel.sysrq = 0`

## ⚠ Cross-cutting caveat: CONFIDENTIALITY vs the scx latency work

This is the big interaction. [`2026-05-29-latency-sched-ext.md`](2026-05-29-latency-sched-ext.md)
relied on the laptop being `FORCE_NONE` ("so BPF/sched_ext loads fine"). We are
now `FORCE_CONFIDENTIALITY`, which enforces `LOCKDOWN_BPF_READ_KERNEL` — this
**may stop `scx_lavd`/scx_loader from attaching** (struct_ops BPF that reads
kernel memory). If scx refuses to load after this rebuild:
- The in-kernel **EEVDF scheduler still runs unchanged** — no latency cliff,
  just no BORE/CachyOS-class profile.
- To get scx back you must drop the laptop to `FORCE_INTEGRITY` (still blocks
  hibernation, kexec_load, kprobes, BPF kernel *writes*) and rebuild. That's
  the documented fallback in `00-local-laptop.config`.

Decision recorded: user chose **confidentiality knowingly**, accepting possible
scx loss + loss of `perf` kernel profiling, in exchange for the kernel-RAM-read
lockdown (ZFS-key protection).

Secondary: **STACKLEAK** (per-syscall stack erase) and **ZERO_CALL_USED_REGS**
(kernel-wide reg zeroing) each add ~1–2% overhead — minor tension with the
latency tuning, accepted.

## To finish (rebuild was started during the session)

```sh
# User ran this (auto-selected 6.18.33_p1 since 7.x is masked):
emerge gentoo-kernel

# AFTER it completes, before reboot — rebuild out-of-tree modules against the
# reconfigured kernel (no ABI change since RANDSTRUCT is off, so existing
# modules would still load, but this is the correct dist-kernel flow + gives
# zfs/nvidia full STACKLEAK coverage):
emerge @module-rebuild

# Apply the sysctls (or just let them load at next boot):
sysctl --system          # NOTE: kexec_load_disabled=1 is irreversible until reboot
```

### Verify after reboot
```sh
cat /sys/kernel/security/lockdown          # -> none integrity [confidentiality]
cat /sys/power/disk 2>/dev/null            # -> empty (hibernation gone)
zcat /proc/config.gz | grep -E 'GCC_PLUGIN_STACKLEAK|GCC_PLUGIN_LATENT_ENTROPY|ZERO_CALL_USED_REGS|LDISC_AUTOLOAD'
sysctl kernel.kexec_load_disabled kernel.yama.ptrace_scope kernel.io_uring_disabled
# scx smoke test (expected to possibly FAIL under confidentiality):
scx_lavd       # if it won't attach -> EEVDF fallback is fine; see caveat above
```

## Rollback

```sh
cd /etc/portage
# Lockdown / hibernation: restore FORCE_NONE + resume= if you ever need
# hibernation back (also re-add resume= to cmdline + the ZBM property + the
# dracut resume module).
# GCC plugins: if a plugin fails to build, the emerge aborts and the current
# kernel stays bootable (non-destructive). To revert deliberately:
rm /etc/kernel/config.d/20-gcc-plugins.config /etc/kernel/config.d/25-build-hardening.config
# (and restore a 20-no-gcc-plugins.config if you want plugins off again)
emerge --oneshot sys-kernel/gentoo-kernel    # rebuild
# sysctls: rm /etc/sysctl.d/99-hardening.conf  (kexec_load_disabled needs a
#   reboot to clear even after removing the file).
```
Previous-good kernels remain installed (6.18.29, 6.18.33, 6.18.33_p1) for ZBM
boot fallback. All edits are unstaged in the `/etc/portage` git repo at session
end — not yet committed.
