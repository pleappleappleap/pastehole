#!/bin/sh
# Runs on the Mac under launchd. Starts a dispatcher on $SOCKET and one
# autossh reverse tunnel per server listed in $HOSTS_FILE.

PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export PATH

SOCKET=/tmp/pbcopy.sock
HOSTS_FILE="$HOME/.config/pbcopy-tunnel/hosts"
DISPATCHER="$HOME/bin/pbcopy-dispatch"
PROBE_INTERVAL=60   # seconds between end-to-end tunnel probes
PROBE_FAIL_MAX=3    # consecutive probe failures before restarting

SESSION_TOKEN=$(openssl rand -hex 16)

log() { printf 'pbcopy-tunnel: %s\n' "$*" >&2; }

cleanup() {
    log "shutting down"
    for pid in $AUTOSSH_PIDS; do kill "$pid" 2>/dev/null; done
    kill "$SOCAT_PID" 2>/dev/null
    rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM HUP
trap '_probe_received=1' USR1

if [ ! -f "$HOSTS_FILE" ]; then
    log "hosts file not found: $HOSTS_FILE"
    exit 1
fi

HOSTS=$(sed 's/#.*//' "$HOSTS_FILE" | grep -v '^[[:space:]]*$')
if [ -z "$HOSTS" ]; then
    log "no hosts configured in $HOSTS_FILE"
    exit 1
fi

# Send the session token through the tunnel; the dispatcher signals back on
# receipt. Probe traffic never reaches pbcopy — the clipboard is untouched.
check_tunnel() {
    _host="$1"
    _probe_received=0
    log "probing $_host"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$_host" \
        "printf '%s' '$SESSION_TOKEN' | xxd -r -p | pbcopy" 2>/dev/null || {
        log "probe to $_host: SSH failed"
        return 1
    }
    _probe_wait=0
    while [ "$_probe_received" -eq 0 ] && [ "$_probe_wait" -lt 50 ]; do
        sleep 0.1
        _probe_wait=$((_probe_wait + 1))
    done
    if [ "$_probe_received" -eq 0 ]; then
        log "probe to $_host: no response"
        return 1
    fi
}

rm -f "$SOCKET"

socat UNIX-LISTEN:"$SOCKET",fork,mode=0600 \
    "EXEC:'$DISPATCHER' $SESSION_TOKEN $$" &
SOCAT_PID=$!

_socat_wait=0
until [ -S "$SOCKET" ]; do
    sleep 0.1
    _socat_wait=$((_socat_wait + 1))
    if [ "$_socat_wait" -ge 50 ]; then
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

log "waiting for tunnels"
for host in $HOSTS; do
    _startup_attempts=0
    while ! check_tunnel "$host"; do
        _startup_attempts=$((_startup_attempts + 1))
        if [ "$_startup_attempts" -ge 15 ]; then
            log "tunnel to $host failed to come up"
            exit 1
        fi
        sleep 2
    done
    log "tunnel to $host established"
done

log "tunnels up"

_last_probe=$(date +%s)
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
