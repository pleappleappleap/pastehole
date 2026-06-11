# pastehole

Persistent SSH clipboard tunnel: pipe data from any number of remote servers
into your local macOS clipboard, surviving SSH session disconnects.

```sh
remote$ echo hello | pbcopy
# → lands in your Mac's clipboard
```

## How it works

```
remote$ echo foo | pbcopy
     │
     └─ writes to /tmp/pbcopy-<mac-hostname>-<session>.sock
                │
          SSH reverse tunnel  (autossh keeps this alive across disconnects)
                │
     ┌─ socat listener on the Mac reads from /tmp/pbcopy-<mac-hostname>-<session>.sock
     └─ pipes to /usr/bin/pbcopy  →  macOS clipboard
```

A launchd agent on the Mac keeps `socat` and one `autossh` instance per
configured server running continuously. All SSH sessions to a given server
share the same tunnel. It doesn't matter which session is active, or whether
any session is open at all when the copy happens.

## Prerequisites

**Mac**
```sh
brew install autossh socat
```

**Remote server**
```sh
# Debian/Ubuntu
sudo apt install socat xxd

# FreeBSD
pkg install socat vim-lite   # xxd is bundled with vim-lite

# RHEL/CentOS
sudo yum install socat vim-common   # xxd is in vim-common
```

Each remote server must be configured as a host alias in `~/.ssh/config` with
key-based (passwordless) auth.

## Quick install

```sh
git clone https://github.com/pleappleappleap/pastehole && cd pastehole

# Install the Mac side once
./install.sh local

# Install on each remote server (can be run repeatedly for additional servers)
./install.sh remote server1
./install.sh remote server2
```

Or install both sides in one shot:
```sh
./install.sh both server1
```

`install.sh remote` automatically adds the server to
`~/.config/pbcopy-tunnel/hosts` and reloads the launchd agent.

## Manual setup

### Mac

1. Install the tunnel script:
   ```sh
   mkdir -p ~/bin ~/Library/Logs
   install -m 0755 pbcopy-tunnel.sh ~/bin/pbcopy-tunnel
   ```

2. Create the hosts file and add your servers:
   ```sh
   mkdir -p ~/.config/pbcopy-tunnel
   echo "server1" >> ~/.config/pbcopy-tunnel/hosts
   echo "server2" >> ~/.config/pbcopy-tunnel/hosts
   ```

3. Install the launchd agent:
   ```sh
   sed -e "s|@@INSTALL_PATH@@|$HOME/bin/pbcopy-tunnel|" -e "s|@@HOME@@|$HOME|g" \
       org.pastehole.plist > ~/Library/LaunchAgents/org.pastehole.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.pastehole.plist
   ```

### Remote server

1. Install the `pbcopy` wrapper:
   ```sh
   mkdir -p ~/bin && install -m 0755 remote/pbcopy ~/bin/pbcopy
   ```
   Ensure `~/bin` is in your `PATH`. If it isn't, add this to `~/.profile`
   (or `~/.shrc` on FreeBSD):
   ```sh
   export PATH="$HOME/bin:$PATH"
   ```

2. Optional but recommended: add to `/etc/ssh/sshd_config`:
   ```
   StreamLocalBindUnlink yes
   ```
   Then reload sshd (`systemctl reload sshd`, `service sshd reload`, etc.).
   This lets SSH cleanly replace the tunnel socket on reconnect. The
   client-side `StreamLocalBindUnlink=yes` option in `pbcopy-tunnel.sh` covers
   most cases without this, but the server-side setting handles edge cases
   where the socket gets stuck after an unclean disconnect.

## Adding or removing servers

**Add a server:**
```sh
./install.sh remote newserver
# or manually:
echo "newserver" >> ~/.config/pbcopy-tunnel/hosts
launchctl bootout gui/$(id -u)/org.pastehole && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.pastehole.plist
```

**Remove a server:**
Edit `~/.config/pbcopy-tunnel/hosts`, remove the line, then reload:
```sh
launchctl bootout gui/$(id -u)/org.pastehole && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.pastehole.plist
```

## Logs

```sh
tail -f ~/Library/Logs/pbcopy-tunnel.log
```

## Troubleshooting

**`pbcopy: no tunnel socket found`**
The tunnel is down. Check the log on the Mac. Common causes:
- autossh can't reach the remote server (network/key issue)
- The launchd agent isn't loaded: `launchctl list org.pastehole`
- `~/.config/pbcopy-tunnel/hosts` is empty or missing

**`pbcopy: multiple Macs connected; specify a hostname:`**
You have active tunnels from more than one Mac. Pass the Mac's `user@hostname`
(shown in the disambiguation list) or just the hostname if it is unambiguous:
```sh
echo hello | pbcopy user@mymac
echo hello | pbcopy mymac
```

**Clipboard gets nothing / pbcopy silently fails**
- Confirm socat is running on the Mac: `pgrep -a socat`
- Confirm a socket exists on the remote: `ssh <host> 'ls /tmp/pbcopy-*.sock'`
- Test the socket directly from the Mac:
  `echo test | socat - UNIX-CONNECT:"$(ls "$(getconf DARWIN_USER_TEMP_DIR)"pbcopy-*.sock 2>/dev/null | head -1)"`

**Tunnel broken after wake from sleep**
autossh will reconnect automatically within ~90 seconds
(`ServerAliveInterval=30 × ServerAliveCountMax=3`). If it doesn't recover,
check that your SSH key is loaded: `ssh-add -l`.

**Stale socket blocks reconnect**
Set `StreamLocalBindUnlink yes` in `/etc/ssh/sshd_config` on the remote server
(see above). The tunnel script also passes this as a client-side SSH option,
which is usually sufficient.

**Stale socket after Mac hostname change**
If your Mac's FQDN changes between runs (e.g. a VPN that alters the domain
suffix), the old socket may linger in `/tmp` on the remote and trigger the
"multiple Macs connected" error even though only one Mac is active. Fix:
```sh
rm /tmp/pbcopy-$(id -un)@*.sock
```
Then wait for the tunnel to reconnect (up to ~90 seconds).

**Fast user switching**
macOS fast user switching is supported: each Mac user runs their own agent
and gets a separate socket, named `pbcopy-user@hostname-token.sock`. Both
users can tunnel into the same remote account simultaneously without
interfering with each other. Note that the agent requires a console (GUI)
login session; SSH-only logins to the Mac are not supported (no `gui/<uid>`
launchd domain, no pasteboard server).

**Upgrading from an earlier version**
Sockets were previously named `pbcopy-hostname-token.sock` (no user prefix).
After upgrading, old-format sockets on remotes will be cleaned up automatically
on the next reconnect. You can also clean them up manually:
```sh
rm /tmp/pbcopy-*.sock
```

## Files

| File | Destination |
|------|-------------|
| `pbcopy-tunnel.sh` | `~/bin/pbcopy-tunnel` on the Mac |
| `pbcopy-dispatch` | `~/bin/pbcopy-dispatch` on the Mac |
| `org.pastehole.plist` | `~/Library/LaunchAgents/org.pastehole.plist` on the Mac |
| `remote/pbcopy` | `~/bin/pbcopy` on each remote server |
| *(generated)* | `~/.config/pbcopy-tunnel/hosts` (one SSH host alias per line) |
