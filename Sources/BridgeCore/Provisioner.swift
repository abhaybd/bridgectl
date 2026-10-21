import Foundation

public struct BridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Sets bridges up and tears them down, on this Mac and on the relay.
public enum Provisioner {
    /// Writes the private sshd's host key and config, the relay script and authorized_keys.
    public static func writeLocalFiles(_ config: BridgeConfig) throws {
        Paths.ensure()
        if !FileManager.default.fileExists(atPath: Paths.hostKey.path) {
            let r = Shell.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "bridgectl host key",
                                                      "-f", Paths.hostKey.path])
            guard r.ok else { throw BridgeError("Couldn't create the sshd host key: \(r.message)") }
        }
        try write(sshdConfig(port: config.sshdPort), to: Paths.sshdConfig, mode: 0o600)
        try write(relayScript(maxSessions: config.maxSessions), to: Paths.relayScript, mode: 0o700)
        // Each relay key may only run commands on its bridge's target, through relay.sh.
        let keys = config.bridges.map {
            "restrict,pty,command=\"\(Paths.relayScript.path) \($0.target)\" \($0.publicKey)"
        }
        try write(keys.joined(separator: "\n") + "\n", to: Paths.authorizedKeys, mode: 0o600)
    }

    /// Sets up a new bridge so that `ssh <alias>` on `relay` reaches `target` through this Mac.
    public static func add(target: String, relay: String, alias: String? = nil) throws -> Bridge {
        let alias = alias.flatMap { $0.isEmpty ? nil : $0 } ?? target
        for (what, value) in [("cluster", target), ("relay", relay), ("name on the relay", alias)]
        where value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            throw BridgeError("The \(what) must be an ssh host name (letters, digits, '.', '_', '-'), not '\(value)'.")
        }
        var config = BridgeConfig.load()
        if let other = config.bridges.first(where: { $0.relay == relay && $0.alias == alias }) {
            throw BridgeError("\(relay) already uses '\(alias)' for bridge \(other.name). Pick another name on the relay.")
        }
        let controlPath = SSH.options(for: target)["controlpath"] ?? "none"
        if controlPath == "none" {
            throw BridgeError("""
                '\(target)' has no ControlMaster set up, so its login can't be shared. Add this to its \
                Host entry in ~/.ssh/config:
                    ControlMaster auto
                    ControlPath ~/.ssh/sockets/%r@%h-%p
                (and run: mkdir -p ~/.ssh/sockets)
                """)
        }
        let check = SSH.remote(relay, "echo ok", timeout: 25)
        guard check.ok else {
            throw BridgeError("Couldn't log into \(relay) without a prompt (it needs key-based login): \(check.message)")
        }

        var name = "\(relay)-to-\(target)"
        var n = 2
        while config.bridge(named: name) != nil { name = "\(relay)-to-\(target)-\(n)"; n += 1 }

        try writeLocalFiles(config)  // makes sure the host key exists
        let hostKey = try String(contentsOf: Paths.hostKey.appendingPathExtension("pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")

        for _ in 0..<5 {
            let port = Int.random(in: 20000...60000)
            let args = [name, alias, "\(port)", NSUserName(), hostKey, macName(), target].map(Shell.quote)
            let r = SSH.remote(relay, "sh -s -- " + args.joined(separator: " "), input: setupScript, timeout: 60)
            if r.stdout.contains("PORT_IN_USE") { continue }
            guard r.ok, let key = r.stdout.split(separator: "\n").last(where: { $0.hasPrefix("ssh-") }) else {
                throw BridgeError("Setting up \(relay) failed: \(r.message)")
            }
            let bridge = Bridge(name: name, target: target, relay: relay, alias: alias, remotePort: port,
                                publicKey: String(key), paused: false)
            config.bridges.append(bridge)
            try config.save()
            try writeLocalFiles(config)
            return bridge
        }
        throw BridgeError("Couldn't find a free port on \(relay).")
    }

    /// Removes a bridge. Returns a warning if the relay couldn't be cleaned up (it's removed here regardless).
    public static func remove(_ name: String) throws -> String? {
        var config = BridgeConfig.load()
        guard let bridge = config.bridge(named: name) else { throw BridgeError("No bridge named '\(name)'.") }
        let r = SSH.remote(bridge.relay, "sh -s -- \(Shell.quote(name))", input: teardownScript, timeout: 40)
        config.bridges.removeAll { $0.name == name }
        try config.save()
        try writeLocalFiles(config)
        try? FileManager.default.removeItem(at: Paths.log("tunnel-\(name)"))
        return r.ok ? nil : """
            Couldn't clean up on \(bridge.relay) (\(r.message)). There, remove the "bridgectl:\(name)" block \
            from ~/.ssh/bridgectl.conf and ~/.ssh/bridgectl_\(name)*.
            """
    }

    /// Moves a bridge to a new port on its relay (when the old one is stuck, e.g. still held by a
    /// dead session there). Clients pick it up right away: ssh re-reads its config every time.
    public static func movePort(_ name: String) throws -> Int {
        var config = BridgeConfig.load()
        guard let i = config.bridges.firstIndex(where: { $0.name == name }) else { throw BridgeError("No bridge named '\(name)'.") }
        let relay = config.bridges[i].relay
        for _ in 0..<5 {
            let port = Int.random(in: 20000...60000)
            let r = SSH.remote(relay, "sh -s -- \(Shell.quote(name)) \(port)", input: movePortScript, timeout: 40)
            if r.stdout.contains("PORT_IN_USE") { continue }
            guard r.ok, r.stdout.contains("MOVED") else { throw BridgeError("Changing the port on \(relay) failed: \(r.message)") }
            config.bridges[i].remotePort = port
            try config.save()
            return port
        }
        throw BridgeError("Couldn't find a free port on \(relay).")
    }

    public static func setPaused(_ name: String, _ paused: Bool) throws {
        var config = BridgeConfig.load()
        guard let i = config.bridges.firstIndex(where: { $0.name == name }) else { throw BridgeError("No bridge named '\(name)'.") }
        config.bridges[i].paused = paused
        try config.save()
    }

    static func macName() -> String {
        let r = Shell.run("/usr/sbin/scutil", ["--get", "ComputerName"], timeout: 5)
        let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !name.isEmpty ? name : (Host.current().localizedName ?? "this Mac")
    }

    private static func write(_ text: String, to url: URL, mode: mode_t) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, mode)
    }

    private static func sshdConfig(port: Int) -> String {
        """
        # Private sshd for BridgeCtl, generated; edits are overwritten. Only listens on 127.0.0.1,
        # which relays reach through their reverse tunnels.
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(Paths.hostKey.path)
        PidFile \(Paths.sshdPid.path)
        AuthorizedKeysFile \(Paths.authorizedKeys.path)
        AllowUsers \(NSUserName())
        PubkeyAuthentication yes
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes yes
        PermitUserRC no
        # Every client arrives from 127.0.0.1 (the tunnel), so per-source limits would hit all of them.
        PerSourcePenalties no
        MaxStartups 100
        # Marker that relay.sh (the forced command) turns into an sftp session on the target.
        Subsystem sftp __sftp__
        LogLevel INFO

        """
    }

    private static func relayScript(maxSessions: Int) -> String {
        #"""
        #!/bin/bash
        # BridgeCtl forced command (see authorized_keys): runs the client's command on TARGET ($1)
        # over this Mac's authenticated ControlMaster. It never runs anything on this Mac.
        target="$1"
        cmd="$SSH_ORIGINAL_COMMAND"
        if ! /usr/bin/ssh -O check "$target" 2>/dev/null; then
          echo "bridgectl: \#(macName()) isn't logged into $target right now (it may be waiting for a Duo approval). Try again later." >&2
          exit 255
        fi

        # Servers refuse sessions past their MaxSessions on one connection, so ssh runs holding one
        # of a few slot locks (released when it exits); clients beyond that wait for a free slot.
        slot=("\#(Paths.cli)" _with-slot "\#(Paths.run.path)/slots-$target" \#(maxSessions) "$target")
        opts=(-o BatchMode=yes -o ControlMaster=no)
        case "$cmd" in
          __sftp__) exec "${slot[@]}" /usr/bin/ssh "${opts[@]}" -s "$target" sftp ;;
          "")       exec "${slot[@]}" /usr/bin/ssh "${opts[@]}" -t "$target" ;;
        esac
        if [ -n "$SSH_TTY" ]; then opts+=(-t); else opts+=(-T); fi
        exec "${slot[@]}" /usr/bin/ssh "${opts[@]}" "$target" "$cmd"

        """#
    }

    /// Runs on the relay: `sh -s -- NAME ALIAS PORT USER HOSTKEY MAC TARGET`. Prints the client public key.
    private static let setupScript = #"""
        set -e
        name="$1" alias="$2" port="$3" user="$4" hostkey="$5" mac="$6" target="$7"
        if command -v ss >/dev/null 2>&1 && ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port\$"; then
          echo PORT_IN_USE; exit 3
        fi
        umask 077
        mkdir -p ~/.ssh
        key=~/.ssh/bridgectl_$name
        [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C "bridgectl $name ($mac)" -f "$key"
        conf=~/.ssh/bridgectl.conf kh=~/.ssh/bridgectl_known_hosts cfg=~/.ssh/config
        touch "$conf" "$kh" "$cfg"
        strip() { awk -v b="# >>> bridgectl:$name" -v e="# <<< bridgectl:$name" '$0==b{s=1} !s{print} $0==e{s=0}' "$1" > "$1.tmp"; cat "$1.tmp" > "$1"; rm -f "$1.tmp"; }
        strip "$conf"
        cat >> "$conf" <<EOF
        # >>> bridgectl:$name
        # Managed by BridgeCtl on $mac: reaches $target through that Mac. Remove it from BridgeCtl there.
        Host $alias
            HostName 127.0.0.1
            Port $port
            User $user
            IdentityFile ~/.ssh/bridgectl_$name
            IdentitiesOnly yes
            HostKeyAlias bridgectl-$name
            UserKnownHostsFile ~/.ssh/bridgectl_known_hosts
            ServerAliveInterval 30
            ConnectTimeout 15
        # <<< bridgectl:$name
        EOF
        grep -v "^bridgectl-$name " "$kh" > "$kh.tmp" || true
        echo "bridgectl-$name $hostkey" >> "$kh.tmp"
        cat "$kh.tmp" > "$kh"; rm -f "$kh.tmp"
        # Included first so these Host entries win over any older ones for the same names.
        if ! grep -qx 'Include bridgectl.conf' "$cfg"; then
          { echo 'Include bridgectl.conf'; echo; cat "$cfg"; } > "$cfg.tmp"; cat "$cfg.tmp" > "$cfg"; rm -f "$cfg.tmp"
        fi
        cat "$key.pub"
        """#

    /// Runs on the relay: `sh -s -- NAME PORT`. Points the bridge's Host entry at PORT.
    private static let movePortScript = #"""
        set -e
        name="$1" port="$2" conf=~/.ssh/bridgectl.conf
        if command -v ss >/dev/null 2>&1 && ss -Htln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port\$"; then
          echo PORT_IN_USE; exit 3
        fi
        grep -qx "# >>> bridgectl:$name" "$conf"
        awk -v b="# >>> bridgectl:$name" -v e="# <<< bridgectl:$name" -v p="$port" \
          '$0==b{s=1} s && $1=="Port"{print "    Port " p; next} {print} $0==e{s=0}' "$conf" > "$conf.tmp"
        cat "$conf.tmp" > "$conf"; rm -f "$conf.tmp"
        echo MOVED
        """#

    /// Runs on the relay: `sh -s -- NAME`. Undoes setupScript; drops the Include once no bridges are left.
    private static let teardownScript = #"""
        name="$1"
        conf=~/.ssh/bridgectl.conf kh=~/.ssh/bridgectl_known_hosts cfg=~/.ssh/config
        rm -f ~/.ssh/bridgectl_$name ~/.ssh/bridgectl_$name.pub
        if [ -f "$conf" ]; then
          awk -v b="# >>> bridgectl:$name" -v e="# <<< bridgectl:$name" '$0==b{s=1} !s{print} $0==e{s=0}' "$conf" > "$conf.tmp"
          cat "$conf.tmp" > "$conf"; rm -f "$conf.tmp"
        fi
        if [ -f "$kh" ]; then
          grep -v "^bridgectl-$name " "$kh" > "$kh.tmp"; cat "$kh.tmp" > "$kh"; rm -f "$kh.tmp"
        fi
        if [ -f "$conf" ] && ! grep -q '^# >>> bridgectl:' "$conf"; then
          rm -f "$conf" "$kh"
          if [ -f "$cfg" ]; then
            awk 'NR==1 && $0=="Include bridgectl.conf" {skip=1; next} skip && $0=="" {skip=0; next} {skip=0} $0!="Include bridgectl.conf"' "$cfg" > "$cfg.tmp"
            cat "$cfg.tmp" > "$cfg"; rm -f "$cfg.tmp"
          fi
        fi
        exit 0
        """#
}
