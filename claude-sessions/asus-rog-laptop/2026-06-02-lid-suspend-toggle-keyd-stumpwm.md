# Lid-close suspend: fix dead hibernate, global keyd toggle, StumpWM indicator

**Date:** 2026-06-02
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop)
**User asks (in order):** (1) be able to SSH in over Tailscale after an away
reboot; (2) toggle lid-close suspend "from my user st"; (3) bind that toggle to
a key "at kernel level" (chose Super+Backslash); (4) show suspend state in the
StumpWM modeline.

---

## 0. Tailscale-after-reboot (investigated, NO changes — deferred)

Traced the boot chain: `ESP → ZFSBootMenu → dracut → OpenRC`. Findings:
- **Post-boot is already fully unattended:** NetworkManager (all wifi profiles
  autoconnect, currently on the `Galaxy Z Fold7 DDBE` hotspot), `tailscale`, and
  `sshd` are all in the `default` runlevel and start with no login. Tailscale is
  already authenticated (`/var/lib/tailscale/tailscaled.state`, node
  `100.69.203.52`). So once the OS reaches its runlevel it self-reconnects.
- **The only blocker is the ZBM passphrase prompt.** `rpool` is encrypted
  (aes-256-gcm, `keylocation=file:///etc/zfs/zroot.key`); the dracut initramfs
  embeds that key (no second prompt), but **ZFSBootMenu prompts once** to read
  `/boot`. An away reboot sits at that prompt forever.
- Networking/Tailscale "in ZBM/dracut" is the wrong layer (roaming WPA2 hotspot;
  tailscaled in initramfs is impractical). The real fix is unattended ZBM unlock
  = embed the key in the ZBM image **on the unencrypted ESP**, which defeats
  FDE-at-rest on a laptop that travels. Presented the tradeoff; user pivoted
  away before deciding. **No changes made.** Revisit later (TPM-seal vs. accept
  the ESP-key tradeoff vs. keep manual prompt).

---

## 1. elogind lid policy — hibernate was a silent no-op → suspend

**Root cause:** `/etc/elogind/logind.conf.d/50-hibernate-on-lid.conf` set
`HandleLidSwitch=hibernate`, but this kernel has **`CONFIG_HIBERNATION` not set**
(`/sys/power/state` = `freeze mem`, no `/sys/power/disk`; also
`lockdown=confidentiality`). elogind asked for a sleep state the kernel can't
provide → **closing the lid did nothing**. The file's cold-boot rationale was
protecting nothing.

**Change** (renamed file to reflect reality):
`50-hibernate-on-lid.conf` → **`50-suspend-on-lid.conf`**
```ini
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=no      # was "yes"; MUST be "no" for the toggle to work
```
Reloaded with `kill -HUP $(pidof elogind)` (NOT a restart — that tears down the
live X session). Verified `loginctl show-session 1` → `HandleLidSwitch=suspend`.

---

## 2. Global toggle: `/usr/local/bin/lid-suspend-toggle` + keyd Super+Backslash

**Mechanism:** holds/releases a system-wide
`elogind-inhibit --what=handle-lid-switch --mode=block` lock. State in
`/run/lid-suspend-inhibit.{pid,state}` (`off` = inhibited/lid stays awake,
`on` = suspends normally). Honored because `LidSwitchIgnoreInhibited=no`.
Per-boot only (reboot clears `/run` → ENABLED again).

**Created `/usr/local/bin/lid-suspend-toggle`** (root-owned, 0755), key points:
- **Self-elevates:** `if [ "$(id -u)" != 0 ]; then exec sudo -n
  /usr/local/bin/lid-suspend-toggle "$@"; fi`. So keyd (already root) runs it
  directly; `st` typing it re-execs via sudo. One lock/state for both paths.
- `setsid elogind-inhibit … sleep infinity &` so the holder survives the
  launching process exiting (verified the lock persists). Toggle-off kills the
  process group (`kill -TERM -- -PID`).
- Best-effort `notify-send` into st's session (`su -s /bin/sh - st -c
  'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send …'`).
- Root bypasses polkit; for reference, polkit `inhibit-handle-lid-switch` is
  `allow_active=yes` (so st's *active* session could take it directly, but a
  `su`/no-session context is `allow_any=no` → denied — which is why the lock is
  root-held, not st-held).

**keyd** (`/etc/keyd/default.conf`) — added a `[meta]` layer:
```
[meta]
backslash = command(/usr/local/bin/lid-suspend-toggle)
```
`keyd v2.6.0` supports `command()`. Chosen over Shift+F10 (context-menu key) and
over any `Mod+letter` (would steal an emacs Meta / i3 Super / ratpoison C-t
binding globally, since keyd intercepts at evdev). `keyd check` + `keyd reload`
clean; daemon (pid 4841) intact, capslock remap preserved.
- **SELinux:** keyd runs as `initrc_t`, which is in `unconfined_domain_type`
  (+ `dbusd_system_bus_client`, `kern_unconfined`) → `command()` exec, the
  D-Bus call to elogind, and `su` all run with **no AVC denials, no policy
  module needed**. (A `runcon … initrc_t` test failed with EPERM — that's the
  unconfined_t→initrc_t manual-transition restriction, irrelevant to keyd's
  natural fork/exec.)

**sudoers** — `/etc/sudoers.d/lid-suspend` (0440), **user-authorized** (the
auto-mode classifier denied the first attempt as an unrequested privilege grant;
user then explicitly approved):
```
st ALL=(root) NOPASSWD: /usr/local/bin/lid-suspend-toggle
```
`visudo -c` parses OK.

**Removed:** an earlier `/home/st/.local/bin/lid-suspend-toggle` shim. It
collided (same basename, `/usr/local/bin` on PATH) so typing `lid-suspend-toggle`
could hit the root script **as st**, which then couldn't `rm` its root-owned
pidfile and aborted under `set -e`. Self-elevation makes one canonical script
sufficient; the shim is deleted.

**Verified:** root path and st path both toggle cleanly in both directions, no
prompts, no permission errors, state flips correctly, ends ENABLED.

---

## 3. StumpWM modeline indicator (`%S`)

**File:** `/home/st/.stumpwm.d/init.lisp` (uses `(in-package :stumpwm)`).
Existing house pattern: a 10s `cae-ml-refresh` timer caches `%B`/`%L` strings.

**Change:** format string (was `"[^B%n^b] %W ^>%L  %B  %d"`) →
```lisp
(setf *screen-mode-line-format* "[^B%n^b] %W ^>%S%L  %B  %d")
```
Added a `%S` formatter + a short watcher timer:
- `cae-lid-state` reads `/run/lid-suspend-inhibit.state` **directly** (tiny local
  read, no subprocess → no caching needed unlike `%B`/`%L`).
- `cae-ml-formatter-lidsuspend` (`#\S`): returns `"^B^R NOSLEEP ^r^b  "` when
  state=`off`, else `""`. Reverse video (`^R`/`^r`) is palette-independent so it
  stays legible under any wal palette. (Confirmed valid escape codes in
  `color.lisp`; `sync-all-mode-lines` does NOT exist here — used
  `update-all-mode-lines`.)
- `cae-lid-watch` on `(run-with-timer 2 2 …)` calls `update-all-mode-lines` when
  the state changes, so a keypress shows within ~2s instead of waiting out
  `*mode-line-timeout*` (default **60s**). Idempotent across `loadrc`.

Validated the block parses in SBCL before inserting. Applied live via
`stumpish loadrc` (X env: `DISPLAY=:0 XAUTHORITY=/home/st/.Xauthority`) →
"rc file loaded successfully". Verified live: enabled → formatter `""`, modeline
has no `NOSLEEP`; disabled → `NOSLEEP` shown. **Semantics: `NOSLEEP` visible =
lid-close suspend DISABLED; nothing = suspends normally.** Only renders in the
StumpWM session (the keyd toggle itself is global).

---

## PENDING / follow-ups
- **User must physically test Super+Backslash** — keyd captures real hardware
  events, couldn't be synthesized here. If it does nothing, run `keyd monitor`
  to confirm the keycodes (some ROG keys sit on an Fn layer).
- **Label wording:** offered to rename `NOSLEEP` → `SUSPEND OFF` (or `LID:AWAKE`
  / `NO LID SLEEP`); awaiting user choice. One-line change in the `%S` formatter
  + `loadrc`.
- Persisting "disabled" across reboots would need config, not the runtime lock
  (currently resets to ENABLED each boot, by design).

## Files touched (all reversible)
- `/etc/elogind/logind.conf.d/50-hibernate-on-lid.conf` → renamed
  `50-suspend-on-lid.conf`, content edited; elogind SIGHUP-reloaded.
- `/usr/local/bin/lid-suspend-toggle` — **new** (root, 0755, self-elevating).
- `/etc/keyd/default.conf` — added `[meta] backslash = command(...)`; reloaded.
- `/etc/sudoers.d/lid-suspend` — **new** (0440, user-authorized).
- `/home/st/.local/bin/lid-suspend-toggle` — **removed** (was a colliding shim).
- `/home/st/.stumpwm.d/init.lisp` — `%S` formatter + watcher; loadrc-applied.

Related memory: `feedback_helium_lid_suspend`.
