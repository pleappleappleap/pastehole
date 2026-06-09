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
    [ -f "$SCRIPT_DIR/pbcopy-dispatch" ]   || die "pbcopy-dispatch not found"
    [ -f "$SCRIPT_DIR/$PLIST_SRC" ]        || die "$PLIST_SRC not found"
    command -v autossh >/dev/null          || die "autossh not found — brew install autossh"
    command -v socat   >/dev/null          || die "socat not found — brew install socat"

    mkdir -p "$HOME/Library/Logs" "$HOME/bin"
    install -m 0755 "$SCRIPT_DIR/pbcopy-tunnel.sh" "$HOME/bin/pbcopy-tunnel"
    info "installed $HOME/bin/pbcopy-tunnel"
    install -m 0755 "$SCRIPT_DIR/pbcopy-dispatch" "$HOME/bin/pbcopy-dispatch"
    info "installed $HOME/bin/pbcopy-dispatch"

    mkdir -p "$HOME/Library/LaunchAgents"
    _tmp=$(mktemp "$HOME/Library/LaunchAgents/.pbcopy-tunnel.plist.XXXXXX")
    sed -e "s|@@INSTALL_PATH@@|$HOME/bin/pbcopy-tunnel|" \
        -e "s|~/|$HOME/|g" \
        "$SCRIPT_DIR/$PLIST_SRC" > "$_tmp" && mv "$_tmp" "$PLIST_DEST" || {
        rm -f "$_tmp"; die "failed to write plist"
    }
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

    ssh "$host" 'command -v socat >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1 && mkdir -p ~/bin && cat > ~/bin/.pbcopy.tmp && chmod 0755 ~/bin/.pbcopy.tmp && mv ~/bin/.pbcopy.tmp ~/bin/pbcopy' \
        < "$SCRIPT_DIR/remote/pbcopy" || \
        die "remote install failed on $host — are socat and xxd installed? (see README.md Prerequisites)"
    info "installed ~/bin/pbcopy on $host"

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
    echo ""
    echo "Done. Test: ssh $host 'echo hello | pbcopy' then pbpaste on the Mac."
}

case "${1:-}" in
    local)
        install_local
        echo ""
        echo "Done."
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
