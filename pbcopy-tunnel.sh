#!/bin/sh
# Runs on the Mac under launchd. Starts a socat listener on $SOCKET and one
# autossh reverse tunnel per server listed in $HOSTS_FILE.

PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
export PATH

SOCKET=/tmp/pbcopy.sock
HOSTS_FILE="$HOME/.config/pbcopy-tunnel/hosts"

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

rm -f "$SOCKET"

socat UNIX-LISTEN:"$SOCKET",fork,mode=0600 EXEC:'pbcopy' &
SOCAT_PID=$!

sleep 1
if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    log "socat failed to start"
    exit 1
fi

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

while true; do
    kill -0 "$SOCAT_PID" 2>/dev/null || { log "socat exited unexpectedly"; exit 1; }
    for pid in $AUTOSSH_PIDS; do
        kill -0 "$pid" 2>/dev/null || { log "autossh $pid exited unexpectedly"; exit 1; }
    done
    sleep 5
done
