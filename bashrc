# /etc/portage/bashrc — sourced (as bash) for every ebuild phase.
#
# Restore the execute bit that app-misc/ollama-bin strips from its standalone
# runner binaries (llama-server, llama-quantize) on every merge. Upstream ships
# them mode 0644; ollama fork/execs llama-server both for GPU discovery and to
# load every model, so without +x GPU discovery silently fails (CPU fallback,
# total_vram=0) and model loads return "fork/exec ...: permission denied"
# (surfaced in Open WebUI as "error starting ollama ... permission denied").
# The sibling *.so files are mmap'd, not exec'd, so they correctly stay 0644.
#
# Implemented here rather than in /etc/portage/env/ because this Portage parses
# env files strictly as key=value and rejects shell functions ("Invalid token
# '('"). bashrc is always sourced as bash, so the guard below is safe.
# See memory: ollama-bin-exec-bit. Added 2026-06-10.
if [[ ${CATEGORY}/${PN} == app-misc/ollama-bin && ${EBUILD_PHASE} == preinst ]]; then
	for _f in llama-server llama-quantize; do
		if [[ -e ${ED%/}/opt/Ollama/lib/ollama/${_f} ]]; then
			chmod 0755 "${ED%/}/opt/Ollama/lib/ollama/${_f}"
			einfo "ollama-bin-fixperms: restored +x on /opt/Ollama/lib/ollama/${_f}"
		fi
	done
	unset _f
fi
