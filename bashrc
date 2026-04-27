# Pre-emerge ZFS snapshot hook.
# Self-contained: no-ops on machines without zfs or without the configured
# dataset. Fires once per emerge invocation (deduped via a /run flag keyed
# on the emerge process PID, found by walking up the proc tree).

[[ ${EBUILD_PHASE} != setup ]] && return 0

_zfs=/usr/bin/zfs
_dataset=rpool/ROOT/default
_keep=20

[[ -x $_zfs ]] || return 0
SANDBOX_ON=0 "$_zfs" list -H -o name "$_dataset" >/dev/null 2>&1 || return 0

_pid=$PPID
_epid=
while [[ -n $_pid && $_pid -gt 1 ]]; do
    [[ $(ps -o comm= -p "$_pid" 2>/dev/null) == emerge ]] && { _epid=$_pid; break; }
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
done

[[ -n $_epid ]] || return 0
_flag=/run/portage-zfs-snap.${_epid}
[[ -e $_flag ]] && return 0

_ts=$(date +%Y%m%d-%H%M%S)
if SANDBOX_ON=0 "$_zfs" snapshot "${_dataset}@preemerge-${_ts}" 2>/dev/null; then
    : > "$_flag" 2>/dev/null || true
    SANDBOX_ON=0 "$_zfs" list -H -o name -t snapshot -s creation 2>/dev/null \
        | grep -F "${_dataset}@preemerge-" \
        | head -n "-${_keep}" \
        | xargs -r -n1 env SANDBOX_ON=0 "$_zfs" destroy 2>/dev/null
    einfo "ZFS: created snapshot ${_dataset}@preemerge-${_ts}"
fi
