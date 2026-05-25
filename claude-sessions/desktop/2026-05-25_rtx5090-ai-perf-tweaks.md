# RTX 5090 / Gentoo — AI Performance Tuning Playbook (2026-05-25)

A reproducible record of the LLM + image-generation performance tweaks made on this
workstation, written so an AI agent (or future me) can follow and re-apply them.

## System
- **GPU:** NVIDIA RTX 5090 (Blackwell, `sm_120` / compute 12.0, 32 GB).
- **CPU:** Ryzen 9 9950X (16C/32T, AVX-512). **RAM:** 186 GiB DDR5.
- **OS:** Gentoo, **OpenRC** (not systemd), hardened kernel, SELinux permissive.
- **Storage:** ZFS root (ARC kept small on purpose so RAM stays free for big local
  models); f2fs for the model/home area.
- **Display:** the AMD iGPU (`amdgpu`) drives the console; the RTX 5090 is used purely
  for compute. This is what makes the no-reboot GPU recovery (§3) safe.
- **Operational note:** this host is administered remotely, so **reboots are treated as
  high-risk**. Everything below is applied at runtime, and GPU faults are recovered
  WITHOUT rebooting.

## 1) Boot perf script — `/etc/local.d/10-ai-perf.start` (runs via OpenRC `local`)
Applied every boot:
1. **CPU:** set every core's cpufreq `scaling_governor` and `energy_performance_preference`
   to `performance` (default powersave/balance_performance throttled bursty model-load
   and tokenization work).
2. **GPU:** `nvidia-smi -pm 1` — persistence mode, avoids CUDA-context re-init latency.
3. **GPU:** `nvidia-smi -pl 600` — raise power cap from the 575 W default to the 600 W max.
4. **GPU overclock** via NVML VF-offset (see §2).
5. **THP = `madvise`** (see §7).

Use NVML offsets, not Coolbits/Xorg (needs `dev-python/nvidia-ml-py`).

## 2) GPU overclock: +350 core / +2000 mem — and how to validate it
```python
import pynvml as N; N.nvmlInit(); h = N.nvmlDeviceGetHandleByIndex(0)
N.nvmlDeviceSetGpcClkVfOffset(h, 350)   # core MHz
N.nvmlDeviceSetMemClkVfOffset(h, 2000)  # mem MHz
```
- A more aggressive **+425/+2500** passed a short 40 s stress but **wedged the GPU under
  real sustained load**: hung channel with `NV_ERR_RESET_REQUIRED` + GSP RPC timeouts,
  util pinned at 100% / ~217 W with empty VRAM, and CUDA/ComfyUI getting
  `cudaErrorDevicesUnavailable`.
- **Lesson:** short stress tests do NOT catch this card's silent (no-ECC) memory-OC
  instability.
- **+350/+2000** (one notch down) was validated with a **3.5-minute sustained stress**
  (`gpu_stress.py`: fp16 8192² GEMM + a 4 GB buffer read-modify-write loop) — zero
  faults, stable results, clean idle afterward.
- Offset ranges on this card: core −1000..+1000, mem −2000..+6000. If instability ever
  returns, step down (+250/+1500) or go stock (0/0). **Validate any OC change with a
  multi-minute memory-bandwidth stress, not a quick check.**

## 3) No-reboot GPU hang recovery (FLR)
Symptoms of a wedge: `nvidia-smi` shows 100% util with near-empty VRAM and no compute
process; `dmesg` shows `RC watchdog: GPU is probably locked` or `NV_ERR_RESET_REQUIRED`.
```sh
# 1) stop ALL GPU users: docker stop <gpu containers>; kill ComfyUI/SwarmUI; any llama-server
# 2) unload the NVIDIA stack (amdgpu console is independent and stays up):
rmmod nvidia_drm nvidia_uvm nvidia_modeset nvidia
# 3) function-level reset the card  (nvidia-smi -r is refused: card is "primary")
echo 1 >| /sys/bus/pci/devices/0000:01:00.0/reset
# 4) reload + restore:
modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm
nvidia-smi -pm 1 && nvidia-smi -pl 600     # then re-apply OC (§2), restart containers + SwarmUI
```
Confirm health with a real compute check, e.g. `llama-server -ngl 99` on a small model
generating a few tokens.

## 4) Speculative decoding for LLMs — `ollama-spec-proxy`
- A small reverse proxy (`/usr/local/bin/ollama-spec-proxy`, OpenRC service) takes over
  Ollama's API port; the real Ollama is moved to a localhost-only port. Every endpoint is
  passed through UNCHANGED except `POST /api/generate`, which the proxy serves itself via
  `llama-server` + a vocab-matched draft model (lossless speculative decoding), swapping
  models on demand and unloading after an idle TTL.
- Net effect: chat UIs/agents using `/api/chat` keep working; text-completion clients
  (e.g. SillyTavern) get the speedup transparently. One model resident at a time.
- Draft models are mapped per model-family and live in the models dir under `drafts/`.
- **Measured wins (spec on vs off):** code model **+224% (3.2×)**, 91% accept; 70B RP
  **+71%**; 32B RP **+24%**; 13B RP **+13%**. Excluded (flat/negative): already-fast and
  small-active-param MoE models (A3B, mixtral-8x7b). **Rule:** spec decode wins when the
  baseline is NOT already fast AND draft acceptance is decent (~50%+); the deciding factor
  is acceptance, not raw speed.
- **Qwen3-235B (132 GB MoE):** served with `-ngl 99 --cpu-moe` (all attention + KV on GPU,
  expert weights on CPU) + a 0.6B draft → fits in VRAM and runs.

## 5) SageAttention 2.2.0 for image gen
- Built `sageattention-2.2.0` (thu-ml) into the ComfyUI venv (`sm_120`, CUDA 13, gcc-15),
  enabled via `--use-sage-attention`; kept ON by default.
- SDXL benefit is modest (~3–5%; SDPA is already fast on Blackwell with `--fast`); the real
  win is long-sequence models (Flux/video). SA2 is quantized (int8/fp8) attention — an A/B
  vs lossless SDPA (same seed) showed only detail-level differences, same composition.
- `torch.compile` for SDXL was a no-go (`inductor` no gain, `cudagraphs` errors with
  ComfyUI's async allocator); revisit only for Flux/video/DiT.

## 6) CUDA 13 + gcc-15 toolchain
- `nvcc` 13.0.x built against **gcc-15** (to match ComfyUI's cu130 torch for SA2). No CUDA
  13 in the main Gentoo tree; used a community ebuild copied into a **local overlay** and
  patched: (a) dosym layout fix for CUDA 13's real `include`/`lib64` dirs, (b)
  `GCC_MAX_VER=15`, (c) glibc-2.42 `rsqrt`/`rsqrtf` noexcept patch (without it `.cu`
  compiles fail "exception specification incompatible").
- Host compiler pinned to gcc-15 via `make.conf` `CUDAHOSTCXX` / `NVCC_PREPEND_FLAGS`
  (system default gcc-16 is too new — nvcc's `host_config.h` rejects `__GNUC__ > 15`).
- gcc-14 and gcc-15 pinned in `world` so they aren't depcleaned.

## 7) Transparent Huge Pages = `madvise` (measured, not guessed)
- Measured `always` vs `madvise` on CPU inference (llama-server, 13B model, `-ngl 0`):
  **4.69–4.72 vs 4.77 tok/s** — within noise, madvise marginally faster.
- Why: llama.cpp loads model weights via **file-backed mmap**, which the THP `enabled` knob
  (anonymous memory only) does not cover — so it can't help the bandwidth-bound weight
  reads that dominate CPU inference. `madvise` is the safe default (no global-compaction
  latency spikes) with no measurable loss.

## 8) Misc fixes
- **nvidia-container-toolkit hook:** the Gentoo build left NVML/sandboxutils symbols
  undefined → wrapped `/usr/bin/nvidia-container-runtime-hook` to `LD_PRELOAD`
  `libnvidia-ml.so.1` + `libnvidia-sandboxutils.so.1` then exec the original. Re-apply
  after any toolkit update (it overwrites the wrapper).
- **OpenCL:** hid the NVIDIA OpenCL ICD (`/etc/OpenCL/vendors/nvidia.icd` → `.disabled`)
  because llama.cpp's OpenCL backend probe was aborting on a degraded driver state; CUDA is
  used regardless. Permanent fix: rebuild llama-cpp with `-opencl`.
- **numpy miscompile:** a global `-fno-semantic-interposition -fno-plt` (EXTRA_OPT)
  segfaulted numpy on import under GCC 16 → fixed with a per-package env file disabling
  those flags for `dev-python/numpy`.
- **Ollama models on f2fs** so cold loads hit the kernel page cache; ZFS ARC kept small on
  purpose so RAM stays free for big local models.

## Known hardware ceiling (not a software fix)
- 4× dual-rank DDR5 DIMMs run below their rated speed (the AM5 memory controller can't
  drive 4 dual-rank sticks at full rate). This throttles **CPU-offloaded** inference only
  (MoE experts, partial offload — RAM-bandwidth bound); fully GPU-resident models are
  unaffected. Raising it needs a BIOS change (a reboot), so it's deferred.
