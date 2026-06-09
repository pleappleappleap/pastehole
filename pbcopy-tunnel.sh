#!/bin/sh
# Runs on the Mac under launchd. Starts a socat listener on $SOCKET and one
# autossh reverse tunnel per server listed in $HOSTS_FILE.

PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export PATH

SOCKET=/tmp/pbcopy.sock
HOSTS_FILE="$HOME/.config/pbcopy-tunnel/hosts"
PROBE_INTERVAL=60   # seconds between end-to-end tunnel probes
PROBE_FAIL_MAX=3    # consecutive probe failures before restarting

log() { printf 'pbcopy-tunnel: %s\n' "$*" >&2; }

cleanup() {
    log "shutting down"
    for pid in $AUTOSSH_PIDS; do kill "$pid" 2>/dev/null; done
    kill "$SOCAT_PID" 2>/dev/null
    rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM HUP

if [ ! -f "$HOSTS_FILE" ]; then
    log "hosts file not found: $HOSTS_FILE"
    exit 1
fi

HOSTS=$(sed 's/#.*//' "$HOSTS_FILE" | grep -v '^[[:space:]]*$')
if [ -z "$HOSTS" ]; then
    log "no hosts configured in $HOSTS_FILE"
    exit 1
fi

# Send a UUID from the remote through the tunnel and verify it arrives in the
# local clipboard. This exercises the full path: SSH, reverse tunnel, socat,
# pbcopy. Writes to the clipboard briefly; the user's next copy overwrites it.
check_tunnel() {
    _host="$1"
    _token=$(uuidgen)
    log "probing $_host"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$_host" \
        "printf '%s' '$_token' | pbcopy" 2>/dev/null || {
        log "probe to $_host: SSH failed"
        return 1
    }
    sleep 1
    _got=$(pbpaste 2>/dev/null)
    if [ "$_got" != "$_token" ]; then
        log "probe to $_host: expected $_token, got $_got"
        return 1
    fi
}

rm -f "$SOCKET"

socat UNIX-LISTEN:"$SOCKET",fork,mode=0600 EXEC:'pbcopy' &
SOCAT_PID=$!

_deadline=$(( $(date +%s) + 5 ))
until [ -S "$SOCKET" ]; do
    sleep 0.1
    if [ "$(date +%s)" -ge "$_deadline" ]; then
        log "socat failed to start"
        exit 1
    fi
done

AUTOSSH_PIDS=""
for host in $HOSTS; do
    ssh -o BatchMode=yes "$host" "rm -f $SOCKET" 2>/dev/null || true
    autossh -M 0 -N \
        -o "BatchMode=yes" \
        -o "ExitOnForwardFailure=yes" \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "StreamLocalBindUnlink=yes" \
        -R "$SOCKET:$SOCKET" \
        "$host" &
    pid=$!
    AUTOSSH_PIDS="$AUTOSSH_PIDS $pid"
    log "started autossh to $host (PID $pid)"
done

sleep 2

for pid in $AUTOSSH_PIDS; do
    kill -0 "$pid" 2>/dev/null || { log "autossh $pid failed to start"; exit 1; }
done

log "tunnels up"

_last_probe=0
_probe_failures=0
while true; do
    kill -0 "$SOCAT_PID" 2>/dev/null || { log "socat exited unexpectedly"; exit 1; }
    for pid in $AUTOSSH_PIDS; do
        kill -0 "$pid" 2>/dev/null || { log "autossh $pid exited unexpectedly"; exit 1; }
    done

    _now=$(date +%s)
    if [ $((_now - _last_probe)) -ge $PROBE_INTERVAL ]; then
        _probe_ok=1
        for host in $HOSTS; do
            check_tunnel "$host" || { _probe_ok=0; break; }
        done
        if [ "$_probe_ok" -eq 1 ]; then
            _probe_failures=0
        else
            _probe_failures=$((_probe_failures + 1))
            log "probe failed ($_probe_failures/$PROBE_FAIL_MAX)"
            if [ "$_probe_failures" -ge "$PROBE_FAIL_MAX" ]; then
                log "too many consecutive probe failures, restarting"
                exit 1
            fi
        fi
        _last_probe=$_now
    fi

    sleep 5
done
