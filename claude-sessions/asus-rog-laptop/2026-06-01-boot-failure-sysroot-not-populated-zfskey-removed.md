# p1 boot, take 3: `/sysroot` not populated → removed the zfskey hook

**Date:** 2026-06-01 (direct follow-up to
[`2026-06-01-boot-failure-zfskey-hook-fix.md`](2026-06-01-boot-failure-zfskey-hook-fix.md))
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop)
**Symptom (user report):** `6.18.33-p1` now boots far enough to **unlock ZFS**,
but the pivot fails — root ends up mounted on `/` and **`/sysroot` is not
populated** (so switch_root has nothing to pivot into). Recovered by booting an
older kernel. The previous (unguarded-hook) p1 *hung*; this one gets further.

## Diagnosis (evidence, not theory)

The ZFS layout is correct and identical for every kernel:
`rpool/ROOT/gentoo` → `mountpoint=/`, `canmount=noauto`, `encryptionroot=rpool`,
`bootfs=rpool/ROOT/gentoo`. So the pool/dataset is **not** the variable.

Diffed the p1 initramfs against the **working** `6.18.33` image:
- Same **dracut-111**, same **module set** (identical `.ko` basenames), same
  `etc/zfs/zpool.cache`, same hostid (`0abc33d1`).
- The ZFS mount scripts are **byte-identical** (same sizes):
  `98-mount-zfs.sh`, `dracut-zfs-lib.sh`, `95-parse-zfs.sh`, `90-zfs-load-key.sh`.
- The **only** functional difference: p1 carries the custom **`zfskey`** module
  (`pre-mount/89-load-zfs-key.sh` + embedded `etc/zfs/zroot.key`). (Plus the
  expected swap-moved-post-pivot removal of `crypttab.initramfs`/`luks/swap.key`,
  which is root-irrelevant.)

**Why the hook is the culprit (not the kernel):**
- This is a **non-systemd** initramfs. dracut's own `90-zfs-load-key.sh` is a
  **no-op** here (`[ -e /bin/systemctl ] || return 0`). In a normal boot the pool
  import + key load + `mount_dataset … /sysroot` all happen **together** inside
  the mount hook `98-mount-zfs.sh`. The `zfskey` hook splits that apart: it does
  an early `zpool import -N -f rpool` + `zfs load-key` at **pre-mount 89**,
  *before* the mount step.
- Decisive: between the **unguarded** p1 (hung) and the **guarded** p1 (unlocks
  then `/sysroot` empty), the **kernel binary never changed — only the hook
  did**, yet the failure mode changed. The hang previously masked the mount
  step; with the hook now completing, the subsequent dracut mount fails to
  populate `/sysroot`. → the early import/key-load the hook performs is what
  breaks dracut's later `mount -o zfsutil … /sysroot`.

## Change made this session — removed `zfskey` from the p1 initramfs

Goal: restore a **reliable** boot first (single-prompt UX is a nice-to-have that
has now caused three failed p1 boots). Result is functionally identical to every
known-bootable kernel: standard passphrase prompt **in the initramfs**.

Steps (all reversible; nothing deleted):
1. `cp -a` current image → `…/initramfs-6.18.33-p1-….img.broken-mount-zfskey.bak`
2. `mv /etc/dracut.conf.d/91-zfs-key.conf{,.disabled}` (the
   `add_dracutmodules+=" zfskey "` that force-adds it on every regen)
3. Regen, SELinux **Enforcing** throughout, staging labeled `modules_object_t`
   (the depmod/`kmod_t` workaround — see
   [[project_dracut_selinux_modules_object_t]]):
   ```sh
   STG=/var/tmp/dracut-staging; mkdir -p "$STG"; chcon -t modules_object_t "$STG"
   dracut --force --tmpdir "$STG" --omit zfskey \
          --kver 6.18.33-p1-gentoo-dist-hardened \
          /boot/initramfs-6.18.33-p1-gentoo-dist-hardened.img
   rm -rf "$STG"
   ```
4. Verified: no `89-load-zfs-key.sh`, no `zroot.key`, modules = `zfs` only,
   mount scripts intact, parses clean, label `boot_t`, exit 0.

The `91zfskey` module **source** under `/usr/lib/dracut/modules.d/91zfskey/` is
left intact; only the conf that pulls it in is disabled. The keyfile
`/etc/zfs/zroot.key` is untouched.

## PENDING USER REBOOT-TEST (the whole point)

Boot **`6.18.33-p1`** in ZFSBootMenu. This is a clean A/B isolation:
- **If it boots** (one ZBM prompt + one initramfs passphrase prompt → login):
  confirms the `zfskey` hook was the cause. Then we can re-add single-prompt
  **safely** — likely via `keylocation=file:///etc/zfs/zroot.key` on `rpool`
  (dracut's own `98-mount-zfs.sh` runs `zfs load-key rpool`, which reads a
  `file://` keylocation with no prompt) **plus** a guarded fallback — instead of
  the early-import hook. (Tradeoff: file keylocation loses the prompt fallback on
  non-systemd; needs thought before re-enabling.)
- **If it STILL fails identically** (unlocks, `/sysroot` empty): then it is
  **NOT** the hook — it's the **p1 kernel** itself (the May-29 build:
  sched_ext / full PREEMPT / HZ_1000 / BTF, hardening config never merged).
  Next step would be a clean `emerge gentoo-kernel` rebuild of p1.

## Fallbacks / safety net
- Every other kernel still boots (`6.18.33`, `6.18.29`, …) — unchanged.
- p1 image backups in `/boot`:
  `.broken-mount-zfskey.bak` (this session's removed-from image, Jun 1 10:11),
  `.broken-zfskey-unguarded.bak` (Jun 1 09:00, hung), `.pre-zfskey.bak`
  (May 29, no zfskey + old in-initramfs swap).
- To re-enable zfskey later: `mv 91-zfs-key.conf.disabled 91-zfs-key.conf` and
  regen — but only after fixing the early-import-vs-mount interaction.

## Still pending from prior sessions
- Phase 2 hardening kernel (lockdown=CONFIDENTIALITY + gcc-plugins) still
  **not merged** — three `emerge gentoo-kernel` runs compiled but never merged.
- `rc_parallel="YES"` (in `/etc/rc.conf`, outside repo) also rides this boot.
- Kernel-config edits remain uncommitted in the `/etc/portage` working tree.
