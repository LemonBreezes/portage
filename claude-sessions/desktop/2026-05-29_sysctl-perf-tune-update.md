# sysctl 90-perf-tune.conf — latency/throughput revision (2026-05-29)

Revision of `/etc/sysctl.d/90-perf-tune.conf` on this workstation (Ryzen 9 9950X,
186 GiB DDR5, RTX 5090, ZFS root, OpenRC). Backup mirror updated at
`/etc/portage/other-backup-stuff/sysctl.d/90-perf-tune.conf`. See
[2026-05-25_rtx5090-ai-perf-tweaks.md](2026-05-25_rtx5090-ai-perf-tweaks.md) for the
broader AI-perf playbook this complements.

## What changed and why

### VM / writeback
- **Dropped the inert `vm.dirty_ratio` / `vm.dirty_background_ratio` lines.** The kernel
  zeroes the `*_ratio` knobs once the `*_bytes` knobs are set, so they were dead config.
  We now set **only** `vm.dirty_bytes = 50331648` (48 MiB) and
  `vm.dirty_background_bytes = 16777216` (16 MiB) — an aggressive low-latency dirty cap so
  writeback can't accumulate enough to stall everything when it flushes.
  - **Tuning knob:** raise `dirty_bytes` to `268435456` (256 MiB) if bulk model *writes*
    start throttling.
- **Added `vm.stat_interval = 10`** — less periodic vmstat aggregation across 32 threads,
  i.e. less scheduling jitter.

### Network
- **`net.ipv4.tcp_timestamps` 0 → 1.** Turned timestamps back ON: BBR needs accurate RTT
  sampling and PAWS needs them on fast links. Modern kernels randomize the offset, so
  there's no uptime-leak concern. (Previously disabled — that was working against BBR,
  which is the configured congestion control.)
- **Added `net.ipv4.tcp_notsent_lowat = 131072`** (128 KiB) — caps unsent data buffered per
  socket before pushing back on the writer. Cuts local queueing latency for
  streaming/interactive flows (token streaming, SSE, ssh over tailnet) without starving
  single-flow throughput.
- **Added `net.core.netdev_max_backlog = 16384`** — deeper per-CPU ingress queue, fewer
  drops under HF-download / tailnet pps bursts.

## Unchanged (context)
- `vm.swappiness`, `vm.vfs_cache_pressure = 50`, `vm.zone_reclaim_mode = 0` (single-socket
  NUMA) as before. TCP: BBR + `tcp_fastopen = 3`, `tcp_mtu_probing = 1`, SACK on,
  `tcp_slow_start_after_idle = 0`, faster TW reuse / shorter FIN wait, tuned keepalives.

## Apply
Runtime knobs, no reboot (this host is administered remotely — reboots are high-risk):
```sh
sysctl --system          # or: sysctl -p /etc/sysctl.d/90-perf-tune.conf
```
Verify a couple: `sysctl vm.dirty_bytes net.ipv4.tcp_timestamps net.ipv4.tcp_notsent_lowat`
