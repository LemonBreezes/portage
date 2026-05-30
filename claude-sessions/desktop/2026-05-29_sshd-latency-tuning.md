# sshd low-latency drop-in (2026-05-29)

Connect-time latency / responsiveness tuning for OpenSSH on this workstation
(`hydrogen`, Ryzen 9 9950X w/ AES-NI, OpenRC). Pure drop-in — `/etc/ssh/sshd_config`
already ends with `Include "/etc/ssh/sshd_config.d/*.conf"`, so no edit to the main
file. **No hardening reduction**: everything here is either a round-trip removal or an
AEAD-cipher reorder. Companion to the network sysctl work in
[2026-05-29_sysctl-perf-tune-update.md](2026-05-29_sysctl-perf-tune-update.md).

## File
- **Live:** `/etc/ssh/sshd_config.d/10-latency.conf` (mode 0644)
- **Backup mirror:** `/etc/portage/other-backup-stuff/ssh/sshd_config.d/10-latency.conf`

## What it sets and why
- **`UseDNS no`** — skip reverse-DNS (PTR) lookup of the client at connect time. A
  slow/unanswered PTR query is the single most common cause of multi-second SSH connect
  stalls. Already the modern default; set explicitly so it can't regress.
- **`Compression no`** — stream compression costs CPU and adds latency on fast/WiFi
  links; off is the modern default, kept explicit.
- **`Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305@openssh.com`**
  — prefer AES-GCM first: with AES-NI on the 9950X, AES-GCM out-throughputs the
  chacha20-poly1305 default for scp/sftp bulk transfer. chacha20 retained as fallback for
  AES-NI-less clients. All three are strong AEAD ciphers.
- GSSAPI/Kerberos round-trip is already absent — OpenSSH here is built without the
  `kerberos` USE flag, so there's nothing to disable.

## Applied (this session)
- `sshd -t` → config valid.
- `sshd -T | grep -Ei '^(usedns|compression|ciphers) '` confirmed the effective values.
- **`rc-service sshd reload`** (SIGHUP) — applied to the running daemon. Reload (not
  restart) keeps existing sessions alive, important since this host is administered
  remotely.

## Re-verify / re-apply
```sh
sshd -t                                   # validate before any reload
rc-service sshd reload                     # apply; existing sessions survive
sshd -T | grep -Ei '^(usedns|compression|ciphers) '
```

## Rollback
```sh
rm /etc/ssh/sshd_config.d/10-latency.conf
sshd -t && rc-service sshd reload
# (remove the backup mirror under other-backup-stuff/ssh/sshd_config.d/ too)
```
