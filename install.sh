#!/bin/sh
# Installs pastehole on the Mac and/or a remote server.
# Usage:
#   ./install.sh local               — Mac side only
#   ./install.sh remote <ssh-host>   — remote side only (via ssh/scp)
#   ./install.sh both   <ssh-host>   — both sides
set -e

PLIST_NAME=io.github.pastehole
PLIST_SRC=io.github.pastehole.plist
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
HOSTS_FILE="$HOME/.config/pbcopy-tunnel/hosts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }

reload_agent() {
    if launchctl list "$PLIST_NAME" >/dev/null 2>&1; then
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
    fi
    launchctl load -w "$PLIST_DEST"
}

install_local() {
    echo "==> Mac side"

    [ -f "$SCRIPT_DIR/pbcopy-tunnel.sh" ]  || die "pbcopy-tunnel.sh not found"
    [ -f "$SCRIPT_DIR/$PLIST_SRC" ]        || die "$PLIST_SRC not found"
    command -v autossh >/dev/null          || die "autossh not found — brew install autossh"
    command -v socat   >/dev/null          || die "socat not found — brew install socat"

    mkdir -p "$HOME/Library/Logs" "$HOME/bin"
    install -m 0755 "$SCRIPT_DIR/pbcopy-tunnel.sh" "$HOME/bin/pbcopy-tunnel"
    info "installed $HOME/bin/pbcopy-tunnel"

    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|@@INSTALL_PATH@@|$HOME/bin/pbcopy-tunnel|" \
        "$SCRIPT_DIR/$PLIST_SRC" > "$PLIST_DEST"
    info "installed $PLIST_DEST"

    mkdir -p "$(dirname "$HOSTS_FILE")"
    if [ ! -f "$HOSTS_FILE" ]; then
        printf '# One SSH host alias per line.\n# Add servers: ./install.sh remote <ssh-host>\n' \
            > "$HOSTS_FILE"
        info "created $HOSTS_FILE"
    fi

    info "Mac side ready. Add a remote server to activate the tunnel:"
    info "  ./install.sh remote <ssh-host-alias>"
}

install_remote() {
    host="$1"
    [ -n "$host" ] || die "usage: $0 remote <ssh-host-alias>"

    echo "==> Remote side ($host)"

    [ -f "$SCRIPT_DIR/remote/pbcopy" ] || die "remote/pbcopy not found"
    command -v ssh >/dev/null          || die "ssh not found"
    command -v scp >/dev/null          || die "scp not found"

    scp -q "$SCRIPT_DIR/remote/pbcopy" "$host:/tmp/pbcopy-wrapper"
    ssh "$host" 'install -m 0755 /tmp/pbcopy-wrapper /usr/local/bin/pbcopy && rm /tmp/pbcopy-wrapper'
    info "installed /usr/local/bin/pbcopy on $host"

    mkdir -p "$(dirname "$HOSTS_FILE")"
    if grep -qxF "$host" "$HOSTS_FILE" 2>/dev/null; then
        info "$host already in $HOSTS_FILE"
    else
        echo "$host" >> "$HOSTS_FILE"
        info "added $host to $HOSTS_FILE"
    fi

    if [ -f "$PLIST_DEST" ]; then
        reload_agent
        info "launchd agent (re)loaded"
    else
        info "Mac side not installed yet — run: ./install.sh local"
    fi

    echo ""
    echo "  NOTE: for clean tunnel reconnects, add to /etc/ssh/sshd_config on $host:"
    echo "    StreamLocalBindUnlink yes"
    echo "  See README.md for details."
}

case "${1:-}" in
    local)
        install_local
        ;;
    remote)
        install_remote "${2:-}"
        ;;
    both)
        install_local
        echo ""
        install_remote "${2:-}"
        ;;
    *)
        echo "usage: $0 local | remote <ssh-host> | both <ssh-host>" >&2
        exit 1
        ;;
esac

echo ""
echo "Done. Test: ssh <host> 'echo hello | pbcopy' then pbpaste on the Mac."
