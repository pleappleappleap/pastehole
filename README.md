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
     └─ writes to /tmp/pbcopy.sock  (Unix socket, same path on both sides)
                │
          SSH reverse tunnel  (autossh keeps this alive across disconnects)
                │
     ┌─ socat listener on the Mac reads from /tmp/pbcopy.sock
     └─ pipes to /usr/bin/pbcopy  →  macOS clipboard
```

A launchd agent on the Mac keeps `socat` and one `autossh` instance per
configured server running continuously. All SSH sessions to a given server
share the same tunnel — it doesn't matter which session is active, or whether
any session is open at all when the copy happens.

## Prerequisites

**Mac**
```sh
brew install autossh socat
```

**Remote server**
```sh
# Debian/Ubuntu
sudo apt install socat

# FreeBSD
pkg install socat

# RHEL/CentOS
sudo yum install socat
```

Each remote server must be configured as a host alias in `~/.ssh/config` with
key-based (passwordless) auth.

## Quick install

```sh
git clone https://github.com/your-username/pastehole && cd pastehole

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
   cp io.github.pastehole.plist ~/Library/LaunchAgents/
   launchctl load -w ~/Library/LaunchAgents/io.github.pastehole.plist
   ```

### Remote server

1. Install the `pbcopy` wrapper:
   ```sh
   install -m 0755 remote/pbcopy /usr/local/bin/pbcopy
   ```

2. Optional but recommended — add to `/etc/ssh/sshd_config`:
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
launchctl kickstart -k gui/$(id -u)/io.github.pastehole
```

**Remove a server:**
Edit `~/.config/pbcopy-tunnel/hosts`, remove the line, then reload:
```sh
launchctl kickstart -k gui/$(id -u)/io.github.pastehole
```

## Logs

```sh
tail -f ~/Library/Logs/pbcopy-tunnel.log
```

## Troubleshooting

**`pbcopy: tunnel socket /tmp/pbcopy.sock not found`**
The tunnel is down. Check the log on the Mac. Common causes:
- autossh can't reach the remote server (network/key issue)
- The launchd agent isn't loaded: `launchctl list io.github.pastehole`
- `~/.config/pbcopy-tunnel/hosts` is empty or missing

**Clipboard gets nothing / pbcopy silently fails**
- Confirm socat is running on the Mac: `pgrep -a socat`
- Confirm the socket exists: `ls -la /tmp/pbcopy.sock`
- Test the socket directly from the Mac:
  `echo test | socat - UNIX-CONNECT:/tmp/pbcopy.sock`

**Tunnel broken after wake from sleep**
autossh will reconnect automatically within ~90 seconds
(`ServerAliveInterval=30 × ServerAliveCountMax=3`). If it doesn't recover,
check that your SSH key is loaded: `ssh-add -l`.

**Socket already exists and blocks reconnect**
Set `StreamLocalBindUnlink yes` in `/etc/ssh/sshd_config` on the remote server
(see above). The tunnel script also passes this as a client-side SSH option,
which is usually sufficient.

## Files

| File | Destination |
|------|-------------|
| `pbcopy-tunnel.sh` | `~/bin/pbcopy-tunnel` on the Mac |
| `io.github.pastehole.plist` | `~/Library/LaunchAgents/io.github.pastehole.plist` on the Mac |
| `remote/pbcopy` | `/usr/local/bin/pbcopy` on each remote server |
| *(generated)* | `~/.config/pbcopy-tunnel/hosts` — one SSH host alias per line |
