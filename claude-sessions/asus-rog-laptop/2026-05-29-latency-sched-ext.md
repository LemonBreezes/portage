# Latency tuning via 1000 Hz + full PREEMPT + sched_ext/scx

**Date:** 2026-05-29
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop)
**Goal:** Lower desktop **scheduling latency** (priority: latency > throughput,
but *not* RT) while keeping the full `gentoo-kernel[hardened]` + SELinux +
module-signing + ZFS-root stack 100% intact.

## Decision

Chose **option B**: do **not** switch kernels (no XanMod / pf / CachyOS).
Instead tune the existing hardened `sys-kernel/gentoo-kernel` dist-kernel and
add `sched_ext` so BORE/CachyOS-class BPF schedulers (`scx_lavd`) can run at
runtime. This keeps:

- All KSPP / hardened distconfig hardening, lockdown LSM wiring, kexec sig
  enforcement (see `00-local-laptop.config`).
- dist-kernel integration: `zfs-kmod` / `nvidia-drivers` auto-rebuild, UKI,
  module signing, and the `dist-kernel-cap` ZFS safety net — untouched,
  because the kernel *package and version* don't change.
- ZFS root safety: no kernel version bump, so `zfs-kmod-2.3.6`
  (`MODULES_KERNEL_MAX=6.19`) is irrelevant here. Nothing can leave root
  unbootable from a version mismatch.

Why not the others: `xanmod-kernel` (parona-overlay) is the only one packaged
as a dist-kernel, but its win is a tuned EEVDF + 1000 Hz that we can reproduce
here; `pf-sources` (gentoo) and CachyOS (unpackaged) are source-only and would
cost the dist-kernel/ZFS-cap automation. `scx_lavd` gives the same latency
scheduler class on *any* kernel, so the kernel choice stops mattering.

## Changes made (all config only — NOT yet built/activated)

### 1. Kernel config fragment (git-tracked, symlinked)
- **File:** `other-backup-stuff/kernel/config.d/30-latency-scx.config`
- **Symlink:** `/etc/kernel/config.d/30-latency-scx.config` -> that file
  (same pattern as the existing 00/10/20 fragments).
- Sets, merged LAST over the hardened distconfig:
  - `CONFIG_HZ_1000=y` / `CONFIG_HZ=1000`  (was 300 Hz)
  - `CONFIG_PREEMPT=y`  (was PREEMPT_LAZY; `PREEMPT_DYNAMIC=y` retained so
    `preempt=full|lazy|voluntary` still overrides at boot, no recompile)
  - `CONFIG_SCHED_CLASS_EXT=y`  (the sched_ext feature)
  - `CONFIG_DEBUG_INFO_BTF=y` + `DWARF_TOOLCHAIN_DEFAULT`  (REQUIRED for scx;
    box was `DEBUG_INFO_NONE`). Cost: longer build, bigger vmlinux, BTF type
    info exposed at `/sys/kernel/btf/vmlinux`.

### 2. Keyword acceptance
- **File:** `package.accept_keywords/zz-autounmask` (new)
- `sys-kernel/scx ~amd64` and `sys-kernel/scx-loader ~amd64` (only ~amd64 in
  tree; `scx` PDEPENDs `scx-loader`). Per house rule, Claude-made keyword/USE
  changes live in `zz-autounmask`; promote to `main.conf` manually if kept.

## To build & activate (run when ready — heavy + needs reboot)

```sh
# 1. Rebuild the hardened dist-kernel with the new fragment merged in.
#    (Regenerates UKI / signs modules / runs installkernel + zbm postinst.)
emerge --oneshot --verbose sys-kernel/gentoo-kernel

# 2. Sanity-check the merge took before rebooting:
zcat /proc/config.gz                      # (current kernel, for comparison)
# After build, inspect the new build's .config under
#   /usr/src/linux-*/.config  or the kernel pkg's config — expect:
#   CONFIG_HZ=1000, CONFIG_PREEMPT=y, CONFIG_SCHED_CLASS_EXT=y,
#   CONFIG_DEBUG_INFO_BTF=y

# 3. Install the scx schedulers + loader (needs a userspace rust toolchain;
#    pulls one if absent). This may warn about SCHED_CLASS_EXT until the new
#    kernel is running — that's expected (CONFIG_CHECK is ~, non-fatal).
emerge --verbose sys-kernel/scx

# 4. Reboot into the rebuilt kernel.  Verify BTF + sched_ext are live:
ls -l /sys/kernel/btf/vmlinux            # must exist
grep -r . /sys/kernel/sched_ext/ 2>/dev/null | head   # sched_ext present
uname -v                                  # confirm PREEMPT in build string

# 5. Try the latency scheduler manually first:
scx_lavd            # foreground; Ctrl-C to drop back to EEVDF instantly
# When happy, let scx-loader manage it (DBUS, on-demand). Enable the service:
#   OpenRC:  rc-update add scx_loader default && rc-service scx_loader start
#   systemd: systemctl enable --now scx_loader   (if it ships a unit)
# Pick the sched/mode via scx-loader config; scx_lavd = latency profile.
```

## Caveats / watch-list

- **Recompile required** for HZ + sched_ext + BTF (these are build-time). Only
  the preempt *model* is runtime-switchable (via `PREEMPT_DYNAMIC` +
  `preempt=` cmdline). If you only wanted preempt, you wouldn't need a rebuild
  — but HZ and sched_ext do.
- **SELinux:** loading a BPF struct_ops scheduler may trip AVCs the first time
  (scx_loader needs `bpf` class perms). If `scx_lavd`/loader is denied, collect
  with `ausearch -m avc -ts recent` and extend policy (audit2allow) — do NOT
  set permissive.
- **Lockdown:** laptop runs `LOCKDOWN_FORCE_NONE`, so BPF/sched_ext loads fine.
  ⚠ The **desktop** variant (`00-local-desktop.config`, `FORCE_INTEGRITY`)
  blocks BPF writes to kernel memory and will likely **prevent scx from
  attaching**. This fragment is shared, but scx is only usable on the laptop
  unless desktop lockdown is relaxed.
- **Power:** 1000 Hz + full PREEMPT slightly raise idle power / overhead. If
  battery life regresses, boot `preempt=lazy` to claw most of it back without
  rebuilding, or drop the HZ fragment.
- **modprobed-db:** if you later trim the kernel via localmodconfig, make sure
  `CONFIG_SCHED_CLASS_EXT`, `CONFIG_DEBUG_INFO_BTF`, and `CONFIG_BPF*` survive
  (this fragment re-asserts them since it merges last).

## Rollback

```sh
rm /etc/kernel/config.d/30-latency-scx.config            # the symlink
git -C /etc/portage rm other-backup-stuff/kernel/config.d/30-latency-scx.config \
    package.accept_keywords/zz-autounmask                # if committed
emerge --oneshot sys-kernel/gentoo-kernel                # rebuild stock-hardened
emerge --deselect sys-kernel/scx                         # optional
# reboot
```
Previous-good kernels remain installed (6.18.29 + 6.18.33) for boot fallback.
