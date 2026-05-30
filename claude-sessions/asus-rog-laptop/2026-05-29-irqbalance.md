# Enable irqbalance for IRQ/CPU distribution

**Date:** 2026-05-29
**Machine:** ASUS ROG Strix G713PI ("helium" / asus-rog-laptop), 32 logical CPUs
**Goal:** Spread hardware interrupts across all cores instead of letting them
pile onto CPU0, lowering per-core IRQ pressure and improving latency under load.

## Decision

`sys-apps/irqbalance` was already installed but **stopped** and not in any
runlevel — so every IRQ was effectively serviced by CPU0 (the kernel default).
On a 32-thread box with a busy NVMe + AX210 WiFi + NVIDIA dGPU + AMD iGPU, that
single-core bottleneck adds avoidable scheduling/interrupt latency. irqbalance
periodically re-distributes IRQ affinity across cores, which pairs well with the
latency-first tuning in [`2026-05-29-latency-sched-ext.md`](2026-05-29-latency-sched-ext.md)
(1000 Hz + full PREEMPT + scx_lavd).

## Changes made (LIVE — applied immediately, no reboot)

```sh
rc-update add irqbalance default   # start at boot, "default" runlevel
rc-service irqbalance start        # start now
```

- **Runlevel:** `irqbalance | default` (persists across reboot).
- **Status:** started; `/usr/sbin/irqbalance` running as PID-of-the-moment.
- **Config:** `/etc/conf.d/irqbalance` left at stock defaults
  (`IRQBALANCE_OPTS=""`, not oneshot — runs as a persistent daemon that
  rebalances every ~10s). No banned CPUs.

Nothing git-tracked here: OpenRC runlevel state lives in `/etc/runlevels/`, and
`/etc/conf.d/irqbalance` is unmodified, so there's no /etc/portage repo change
to commit for this.

## Caveats / watch-list

- **vs. manual IRQ pinning:** irqbalance will *override* any hand-set
  `/proc/irq/*/smp_affinity`. If you ever pin a specific IRQ (e.g. NIC RX
  queues for a latency-critical workload), exclude it via
  `IRQBALANCE_BANNED_CPUS` or `--banirq` in `IRQBALANCE_OPTS`, else irqbalance
  fights you.
- **SELinux (hardened/SELinux profile):** irqbalance runs as a daemon writing
  `/proc/irq/*/smp_affinity`. If it gets denied, collect with
  `ausearch -m avc -ts recent` and extend policy (audit2allow) — do NOT set
  permissive.
- **Power:** negligible idle cost; the daemon wakes briefly to rebalance. If
  chasing absolute idle power you could set `IRQBALANCE_ONESHOT` to balance once
  at boot then exit, but that loses dynamic rebalancing.

## Rollback

```sh
rc-service irqbalance stop
rc-update del irqbalance default
# IRQ affinities revert to kernel default on next reboot (or echo back to
# smp_affinity manually). Package stays installed.
```
