#!/bin/sh
# Runs on the Mac under launchd. Starts a dispatcher on $SOCKET and one
# autossh reverse tunnel per server listed in $HOSTS_FILE.

PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
umask 077

case "${1:-}" in
    -h|--help)
        printf 'usage: pbcopy-tunnel\n\nDaemon that maintains reverse SSH clipboard tunnels to remote servers.\nNormally run automatically via launchd (org.pastehole); do not invoke directly.\nConfigure servers in ~/.config/pbcopy-tunnel/hosts.\n'
        exit 0 ;;
esac

HOSTS_FILE="$HOME/.config/pbcopy-tunnel/hosts"
DISPATCHER="$HOME/bin/pbcopy-dispatch"
PROBE_INTERVAL=60   # seconds between end-to-end tunnel probes
PROBE_FAIL_MAX=3    # consecutive probe failures before reconnecting

CAP_PCT=10
CAP_CEILING=1073741824   # 1 GiB hard ceiling
_mem=$(sysctl -n hw.memsize 2>/dev/null)
if [ -n "$_mem" ]; then
    CAP_BYTES=$((_mem * CAP_PCT / 100))
    [ "$CAP_BYTES" -gt "$CAP_CEILING" ] && CAP_BYTES=$CAP_CEILING
else
    CAP_BYTES=$CAP_CEILING
fi

log() { printf 'pbcopy-tunnel: %s\n' "$*" >&2; }
ctl_path() { printf '%s/pbcopy-ctl-%s' "${RUNTIME_DIR%/}" "$1"; }

# SESSION_TOKEN is a probe/route discriminator, not a credential. It appears in
# the socket filename and in socat/dispatcher argv (visible via ps to local users).
SESSION_TOKEN=$(openssl rand -hex 16)
MAC_USER=$(id -un)
case "$MAC_USER" in
    *[!a-zA-Z0-9._-]*) log "invalid username: $MAC_USER"; exit 19 ;;
esac
MAC_HOSTNAME=$(hostname -f)
case "$MAC_HOSTNAME" in
    *[!a-zA-Z0-9._-]*) log "invalid hostname: $MAC_HOSTNAME"; exit 1 ;;
esac
RUNTIME_DIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
[ -d "$RUNTIME_DIR" ] || RUNTIME_DIR=${TMPDIR:-/tmp}
SOCK_NAME="pbcopy-${MAC_USER}@${MAC_HOSTNAME}-${SESSION_TOKEN}.sock"
REMOTE_SOCKET="/tmp/${SOCK_NAME}"
LOCAL_SOCKET="${RUNTIME_DIR%/}/${SOCK_NAME}"
if [ "${#LOCAL_SOCKET}" -gt 100 ]; then
    log "socket path too long, using /tmp for local bind"
    LOCAL_SOCKET="/tmp/${SOCK_NAME}"
fi

_cleaned=0
cleanup() {
    [ "$_cleaned" -eq 1 ] && return
    _cleaned=1
    log "shutting down"
    for pid in $MONITOR_PIDS; do kill "$pid" 2>/dev/null; done
    kill "$SOCAT_PID" 2>/dev/null
    rm -f "$LOCAL_SOCKET"
}
trap cleanup EXIT INT TERM HUP

if [ ! -f "$HOSTS_FILE" ]; then
    log "hosts file not found: $HOSTS_FILE"
    exit 2
fi

HOSTS=$(sed 's/#.*//' "$HOSTS_FILE" | grep -v '^[[:space:]]*$')
if [ -z "$HOSTS" ]; then
    log "no hosts configured in $HOSTS_FILE"
    exit 3
fi

# Send session token + host sequence byte through the tunnel.
# The dispatcher echoes the sequence byte back as the ACK.
check_tunnel() {
    _host="$1"
    _seq="$2"
    _probe_hex=$(printf '%s%02x' "$SESSION_TOKEN" "$_seq")
    _ack=$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o "ControlMaster=no" -o "ControlPath=$(ctl_path "$_host")" \
        -- "$_host" \
        "printf '%s' '$_probe_hex' | xxd -r -p | socat - UNIX-CONNECT:'$REMOTE_SOCKET'" 2>/dev/null \
        | head -c 1 | xxd -p | tr -d '\n')
    [ "$_ack" = "$(printf '%02x' "$_seq")" ]
}

# Per-host monitor: manages autossh and periodic probes for one host.
# Reconnects automatically on tunnel failure; never exits in normal operation.
run_host_monitor() {
    _mhost="$1"
    _mseq="$2"
    _mautossh_pid=""
    _mctl=$(ctl_path "$_mhost")
    trap 'kill "$_mautossh_pid" 2>/dev/null; rm -f "$_mctl"' EXIT
    trap 'kill "$_mautossh_pid" 2>/dev/null; rm -f "$_mctl"; exit 0' INT TERM HUP

    while true; do
        rm -f "$_mctl"
        # Transitional glob reaps old-format sockets from pre-upgrade installs; remove in a future release.
        ssh -o BatchMode=yes -- "$_mhost" "find /tmp -maxdepth 1 \
            \( -name 'pbcopy-${MAC_USER}@${MAC_HOSTNAME}-*.sock' \
               -o -name 'pbcopy-${MAC_HOSTNAME}-*.sock' \) -delete 2>/dev/null; true" 2>/dev/null || true

        # Race: SIGTERM between the & and $! assignment below orphans autossh.
        # Window is one interpreter step wide; autossh self-terminates when its
        # keepalive detects the gone socket. Not worth defending against.
        autossh -M 0 -- \
            -N \
            -o "BatchMode=yes" \
            -o "ExitOnForwardFailure=yes" \
            -o "ServerAliveInterval=30" \
            -o "ServerAliveCountMax=3" \
            -o "StreamLocalBindUnlink=yes" \
            -o "StreamLocalBindMask=0177" \
            -o "ControlMaster=yes" \
            -o "ControlPath=${_mctl}" \
            -R "$REMOTE_SOCKET:$LOCAL_SOCKET" \
            -- "$_mhost" &
        _mautossh_pid=$!
        log "[$_mhost] started autossh (PID $_mautossh_pid)"

        _mattempts=0
        _mup=0
        while [ "$_mattempts" -lt 15 ]; do
            if check_tunnel "$_mhost" "$_mseq"; then
                _mup=1
                break
            fi
            _mattempts=$((_mattempts + 1))
            sleep 2
        done

        if [ "$_mup" -eq 0 ]; then
            log "[$_mhost] tunnel failed to come up, will retry"
            kill "$_mautossh_pid" 2>/dev/null
            sleep 30
            continue
        fi

        log "[$_mhost] tunnel established"

        _mlast_probe=$(date +%s)
        _mprobe_failures=0
        while true; do
            kill -0 "$_mautossh_pid" 2>/dev/null || {
                log "[$_mhost] autossh exited, reconnecting"
                break
            }

            _mnow=$(date +%s)
            if [ $((_mnow - _mlast_probe)) -ge "$PROBE_INTERVAL" ]; then
                if check_tunnel "$_mhost" "$_mseq"; then
                    _mprobe_failures=0
                else
                    _mprobe_failures=$((_mprobe_failures + 1))
                    log "[$_mhost] probe failed ($_mprobe_failures/$PROBE_FAIL_MAX)"
                    if [ "$_mprobe_failures" -ge "$PROBE_FAIL_MAX" ]; then
                        log "[$_mhost] too many probe failures, reconnecting"
                        break
                    fi
                fi
                _mlast_probe=$_mnow
            fi

            sleep 5
        done

        kill "$_mautossh_pid" 2>/dev/null
        sleep 5
    done
}

rm -f "$LOCAL_SOCKET"

socat UNIX-LISTEN:"$LOCAL_SOCKET",fork,mode=0600,max-children=10 \
    "EXEC:$DISPATCHER $SESSION_TOKEN $CAP_BYTES" &
SOCAT_PID=$!

_socat_wait=0
until [ -S "$LOCAL_SOCKET" ]; do
    sleep 0.1
    _socat_wait=$((_socat_wait + 1))
    if [ "$_socat_wait" -ge 50 ]; then
        log "socat failed to start"
        exit 4
    fi
done

MONITOR_PIDS=""
_seq=0
for host in $HOSTS; do
    (run_host_monitor "$host" "$_seq") &
    MONITOR_PIDS="$MONITOR_PIDS $!"
    log "started monitor for $host (seq $_seq)"
    _seq=$((_seq + 1))
done

log "monitors started"

while true; do
    kill -0 "$SOCAT_PID" 2>/dev/null || { log "socat exited unexpectedly"; exit 5; }
    for pid in $MONITOR_PIDS; do
        kill -0 "$pid" 2>/dev/null || { log "a host monitor exited unexpectedly"; exit 6; }
    done
    sleep 5
done
