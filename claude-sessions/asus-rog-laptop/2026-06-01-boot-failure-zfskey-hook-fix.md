# Boot failure after the hardening session — root cause + zfskey hook fix + rc_parallel

**Date:** 2026-06-01 (same day as, and a direct follow-up to,
[`2026-06-01-kernel-hardening-lockdown-plugins.md`](2026-06-01-kernel-hardening-lockdown-plugins.md))
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop)
**Symptom (user report):** system failed to boot after the recent changes;
recovered by selecting a different kernel in the ZFSBootMenu.

## Root cause

The failing kernel entry was **`6.18.33-p1`**. Booting any other kernel worked
because they still carry their older, known-good initramfs.

**The boot-breaker was the custom `zfskey` dracut module's pre-mount hook**, not
the kernel hardening. The June 1 initramfs regen (09:00) added
`/usr/lib/dracut/modules.d/91zfskey` → installs `89-load-zfs-key.sh` on the
pre-pivot critical path, which ran an **unguarded, no-timeout**
`zpool import -N -f rpool` + `udevadm settle` before dracut's own
`90-zfs-load-key.sh`. A slow/missing device wedges that synchronous hook → boot
stalls. It is the only pre-pivot, p1-only change, which is why switching kernels
(different initramfs, standard passphrase prompt) recovered cleanly.

### Suspects ruled OUT with evidence
- **Kernel hardening config (lockdown=CONFIDENTIALITY, gcc-plugins,
  zero-call-regs) was never installed.** Three `emerge gentoo-kernel` runs on
  June 1 compiled into `/var/tmp/portage` (`.compiled` marker, modules signed)
  but **none completed the merge** — no Merging/completed line in
  `/var/log/emerge.log`. `/boot/vmlinuz-…-p1` is still the **May 29** image with
  the OLD config (`FORCE_NONE`, no plugins, `ZERO_CALL_USED_REGS` off,
  HIBERNATION already off). Confirmed by diffing the installed p1 `.config`
  against the running `config.gz`: the only deltas were the May 29 sched_ext
  work (`SCHED_CLASS_EXT`, full `PREEMPT`, `HZ_1000`, BTF), NOT the hardening.
- **Encrypted-swap redesign is fine.** Swap moved to post-pivot OpenRC `dmcrypt`
  (`target=swap`, in the `boot` runlevel) and is active right now
  (`/dev/dm-0`, 100G). A post-pivot failure would break *every* kernel, not just
  p1 — but switching kernels fixed it, so the failure is pre-pivot.
- **Module signing not the variable.** `MODULE_SIG_FORCE=y` is enforced on the
  *working* kernel too; each gentoo-kernel build self-signs with a per-build
  ephemeral key. Both kernels are self-consistent.

### initramfs diff that nailed it (p1: Jun 1 09:00 vs `.pre-zfskey.bak` May 29)
| File | May 29 `.bak` | Jun 1 (failed) |
|---|---|---|
| `etc/crypttab.initramfs` | present | gone (swap moved post-pivot — OK) |
| `etc/luks/swap.key` | present | gone (OK) |
| `etc/zfs/zroot.key` | — | 18-byte passphrase (new) |
| `zfskey` module / `89-load-zfs-key.sh` | no | **yes (the culprit)** |
| `resume` module | yes | yes (still present; no-ops, resume= gone) |

## Changes made this session

### 1. Repaired the `zfskey` pre-mount hook (the actual fix)
**Files (NOT in the /etc/portage git repo — live under `/usr/lib/dracut/modules.d/91zfskey/`):**
- `load-zfs-key.sh`: every blocking call now wrapped in `timeout -k`
  (`udevadm settle` 10s, `zpool import` 20s, `zfs load-key` 15s). On any
  timeout/failure it `exit 0` → dracut's own `90-zfs-load-key.sh` does the
  normal interactive prompt. **Worst case is the old two-prompt boot, never a
  hang.** Also added `command -v timeout || exit 0` guard.
- `module-setup.sh`: added `inst_multiple timeout` so the guard binary is
  guaranteed present in the initramfs.

### 2. Validated the embedded key (non-destructive)
`zfs load-key -n -L file:///etc/zfs/zroot.key rpool` → **`1/1 key(s)
successfully verified`**. The 18-byte passphrase was always correct; the only
fault was the unguarded hook. So the single-passphrase UX will actually work
(one prompt at ZBM, none in the initramfs), not just fall back.

### 3. Regenerated the p1 initramfs under SELinux enforcing
```sh
STG=/var/tmp/dracut-staging
mkdir -p "$STG"; chcon -t modules_object_t "$STG"   # see note below
dracut --force --tmpdir "$STG" --kver 6.18.33-p1-gentoo-dist-hardened \
       /boot/initramfs-6.18.33-p1-gentoo-dist-hardened.img
rm -rf "$STG"
```
Verified: 4 `timeout -k` guards in the embedded hook, `zroot.key` + `timeout`
present, 2375 files, parses clean, image labeled `boot_t`. SELinux stayed
**Enforcing** throughout (never weakened).

**SELinux gotcha (recorded as a memory):** manual `dracut` fails under enforcing
because `depmod` transitions to `kmod_t`, which cannot read dracut's staging
tree (default `user_tmp_t`):
`avc: denied { read } comm="depmod" scontext=…:kmod_t tcontext=…:user_tmp_t tclass=lnk_file`.
`setenforce 0` is the wrong tool (global security-weaken; correctly blocked).
Labeling the scratch dir `modules_object_t` (what the real `/lib/modules` tree
uses, and what `kmod_t` reads by design) fixes it with no policy change.
⚠ `emerge gentoo-kernel`'s internal installkernel→dracut step will hit the SAME
denial — handle Phase 2 with a persistent `tmpdir=` (dracut.conf.d) on a dir
with an fcontext pinning `modules_object_t`, or regen the initramfs by hand
afterward.

### 4. Boot-time speedup: `rc_parallel="YES"`
**File:** `/etc/rc.conf` (live system file, NOT in /etc/portage repo) — added
active `rc_parallel="YES"` below the commented default. Default runlevel's 16
services were starting sequentially; they now start concurrently (deps still
honored; `rc_interactive` "I" key auto-disabled; console lines get
service-name prefixes). Takes effect next boot.

Measured boot profile (current 6.18.33, ~35s to login) that motivated it:
kernel init 0→5.6s · initramfs ZFS import+key+mount (incl. 2nd passphrase)
5.6→~12.9s · pivot + boot runlevel + SELinux policy ~12.9→~21.6s · **default
runlevel (sequential) → login ~21.6→~35.5s** ← the target.

## Backups / safety net (p1 boot path)
- `…/initramfs-6.18.33-p1-…img.broken-zfskey-unguarded.bak` — the Jun 1 broken one
- `…/initramfs-6.18.33-p1-…img.pre-zfskey.bak` — May 29, pre-zfskey (two-prompt + in-initramfs swap)
- All other kernels (6.18.33, 6.18.29, …) untouched and bootable

## State at session end / TO DO
- **PENDING USER REBOOT-TEST:** boot `6.18.33-p1` in ZBM. Expected: one ZBM
  passphrase prompt, then straight through (no 2nd prompt). Note: `rc_parallel`
  also rides this boot — userspace-phase issues → suspect `rc_parallel`
  (comment line 11 of `/etc/rc.conf`); pre-pivot stall → suspect initramfs
  (restore a `.bak`). Phases don't overlap.
- **Phase 2 (after p1 boot confirmed):** finish the hardening kernel
  (`emerge gentoo-kernel` to merge lockdown=CONFIDENTIALITY + gcc-plugins, then
  `@module-rebuild`), working around the SELinux/depmod wall (see §3 note).
  Recall the scx caveat: CONFIDENTIALITY may stop `scx_lavd` attaching (EEVDF
  fallback fine).
- **Optional further boot wins (discussed, NOT applied):** lower ZBM menu
  timeout from ~10s to ~3s (after recovery is over — keep it for now to pick
  fallback kernels); dracut `hostonly="yes"` (smaller/faster, loses portability
  — conflicts with the deliberate `hostonly="no"`); drop `init_on_free=1` keep
  `init_on_alloc=1` (security tradeoff). Compression already zstd (dracut-111).
- Kernel-config changes from the prior session remain **uncommitted** in the
  `/etc/portage` working tree. `/etc/rc.conf` and the `91zfskey` module live
  outside the repo.
