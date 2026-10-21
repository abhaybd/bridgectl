# BridgeCtl

A macOS menu bar app that lets programs on a remote machine reach a cluster they can't reach
themselves, by hopping through your Mac and reusing its already-logged-in (e.g. Duo) connection.

The motivating case: agents run on a machine called `workstation`, experiments run on a Slurm
cluster called `cluster`. `cluster` blocks ssh from `workstation` and wants Duo for every new login,
but your laptop can log in and keeps a ControlMaster connection open. With a bridge set up,
`ssh cluster` (and `rsync`, `scp`, `sbatch` over ssh, ...) just works on `workstation`, with no Duo
prompts there.

```
workstation                                          your Mac                                        cluster
ssh cluster ──► 127.0.0.1:PORT ═══reverse tunnel═══► private sshd ──► relay.sh ──► ControlMaster ──► sshd
                 (local port)   (opened by the Mac) (127.0.0.1 only) (forced cmd) (Duo done once)
```

- **Reverse tunnel.** The Mac keeps `ssh -R` open to the relay (`workstation`), so the relay can
  reach the Mac without the Mac accepting any inbound connection from the network.
- **Private sshd.** The app runs its own sshd as you, listening only on the Mac's `127.0.0.1`, with
  its own host key and `authorized_keys`. macOS Remote Login stays off.
- **Forced command.** Each relay gets its own key, which can do exactly one thing: run the
  requested command on its target over your existing ControlMaster (`relay.sh`). It can't run
  anything on the Mac, forward ports or open new logins.
- **Staying logged in.** When the target's ControlMaster is gone (sleep, network change, server
  timeout), the app opens a new one and shows the login prompt in a dialog. For Duo, `1`
  (Duo Push) is pre-filled, so it's Enter plus approving on your phone. If you click
  **Not Now**, it asks again in 20 minutes (or use **Log In Now**).
- **Sleep and network changes.** On wake or a network change, tunnels reconnect at once instead of
  waiting for ssh to notice the old connection died. A tunnel's stale port on the relay is freed
  before reconnecting.

While the Mac is asleep or offline, bridges are down; clients get a clear error and work again
once it's back (after a Duo approval if the login didn't survive).

## Requirements

- macOS 13+, Xcode command line tools (`xcode-select --install`) to build.
- The target (`cluster`) has a ControlMaster in this Mac's `~/.ssh/config`:
  ```
  Host cluster
      HostName cluster.local
      User you
      ControlMaster auto
      ControlPath ~/.ssh/sockets/%r@%h-%p
  ```
  (`mkdir -p ~/.ssh/sockets`). Your own `ssh cluster` sessions share the same login.
- The Mac can ssh into the relay (`workstation`) with a key, no prompts.

## Install

```bash
scripts/install.sh
```

This builds `~/Applications/BridgeCtl.app`, starts it, registers it to start at login (and to
restart if it crashes), and links the CLI to `~/.local/bin/bridgectl`. Run it again after pulling
changes.

## Use

Click the network icon in the menu bar (it shows a slash when something is down):

- **Add Bridge…**: pick the cluster (e.g. `cluster`), the relay (`workstation`) and optionally the name
  to use on the relay (defaults to the cluster's). BridgeCtl generates a key on the relay and adds a
  `Host` entry there.
- Each bridge's submenu shows the tunnel and login state, and has **Test Connection**,
  **Log In Now**, **Reconnect Tunnel**, **Pause/Resume** and **Remove…**. Removing a bridge deletes
  its key and `Host` entry on the relay.

Or from the terminal:

```bash
bridgectl add cluster --from workstation    # on workstation: ssh cluster
bridgectl status
bridgectl test workstation-to-cluster
bridgectl login cluster                     # ask for Duo now
bridgectl reconnect
bridgectl pause workstation-to-cluster / resume workstation-to-cluster
bridgectl remove workstation-to-cluster
```

On the relay, use the bridge like the real host: `ssh cluster squeue`,
`rsync -a data/ cluster:data/`, `scp`, `ssh -t cluster` for a shell. In scripts, use `ssh -n`
when stdin isn't meant for the remote command, as with any ssh.

## What it changes on a relay

Everything lives in files it owns, plus one line:

- `~/.ssh/config` gets `Include bridgectl.conf` as its first line, so these entries take precedence.
- `~/.ssh/bridgectl.conf`: one `Host` block per bridge, between `# >>> bridgectl:NAME` markers.
- `~/.ssh/bridgectl_NAME` (+ `.pub`): the bridge's client key.
- `~/.ssh/bridgectl_known_hosts`: the Mac's bridge host key.

Removing the last bridge removes all of it, including the `Include` line.

## Files on the Mac

`~/.bridgectl/`: `config.json` (bridges and settings), `status.json` (last state, for the CLI),
`sshd/` (the private sshd's config, host key, `authorized_keys`), `relay.sh`, `logs/` (also under
**Open Logs Folder**) and `run/`.

Settings in `config.json` you may want to change (then restart the app):

- `snoozeMinutes` (20): how long to wait before asking again after a cancelled login.
- `maxSessions` (8): sessions relayed at once per target. Servers refuse sessions past their
  `MaxSessions` (usually 10) on one connection; extra clients wait for a free slot. Keep it below
  the server's limit so your own sessions still fit.

## Security notes

- Anyone who can use your account on the relay can run commands on the target as you. That's the
  point, but keep it in mind on shared machines.
- Nothing on the relay can run commands on the Mac: every key BridgeCtl accepts is restricted to
  relaying to one target (`restrict` + forced command), and the sshd only listens on `127.0.0.1`.

## Uninstall

Remove every bridge first (so relays get cleaned up), then:

```bash
launchctl bootout gui/$(id -u)/com.abhaybd.bridgectl
rm -rf ~/Applications/BridgeCtl.app ~/Library/LaunchAgents/com.abhaybd.bridgectl.plist ~/.bridgectl ~/.local/bin/bridgectl
```
