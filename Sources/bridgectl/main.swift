import BridgeCore
import Foundation

signal(SIGPIPE, SIG_IGN)

let usage = """
    usage: bridgectl <command>

      status                              show bridges and logins (the default)
      add <cluster> --from <relay> [--as <name>]
                                          let `ssh <name>` on <relay> reach <cluster> through this Mac
      remove <bridge>                     remove a bridge (and its setup on the relay)
      pause <bridge> | resume <bridge>    stop / restart a bridge's tunnel, keeping its setup
      login <cluster>                     ask for the cluster login (e.g. Duo) now
      reconnect [<bridge>]                restart tunnels right away
      test <bridge>                       run `ssh <name> hostname` on the relay

    The BridgeCtl menu bar app runs the bridges; this tool changes its setup and asks it to act.
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bridgectl: \(message)\n".utf8))
    exit(1)
}

func bridge(_ name: String?) -> Bridge {
    guard let name else { fail("missing bridge name\n\n\(usage)") }
    guard let b = BridgeConfig.load().bridge(named: name) else {
        fail("no bridge named '\(name)' (see `bridgectl status`)")
    }
    return b
}

func requireApp() {
    if !AppLock.isHeldElsewhere() {
        print("Note: the BridgeCtl app isn't running; changes take effect when it starts.")
    }
}

func status() {
    let config = BridgeConfig.load()
    let running = AppLock.isHeldElsewhere()
    let snapshot = running ? StatusSnapshot.load() : nil
    print("BridgeCtl app: " + (running ? "running" + (snapshot?.sshdUp == false ? " (local sshd is down!)" : "") : "not running"))
    if config.bridges.isEmpty { print("No bridges. Add one with: bridgectl add <cluster> --from <relay>"); return }
    let time = DateFormatter()
    time.timeStyle = .short
    for b in config.bridges {
        let s = snapshot?.bridges.first { $0.name == b.name }
        let tunnel = b.paused ? "paused" : (s?.tunnel ?? "-") + (s?.detail.map { " (\($0))" } ?? "")
        print("\n\(b.name): `ssh \(b.alias)` on \(b.relay) -> \(b.target)")
        print("  tunnel: \(tunnel)")
        let login: String
        if let pid = SSH.masterPID(b.target) {
            login = "logged in (master pid \(pid))"
        } else if let t = snapshot?.targets.first(where: { $0.target == b.target }) {
            login = t.state == "snoozed" ? "not logged in; asking again at \(time.string(from: t.snoozedUntil ?? Date()))"
                                          : t.state
        } else {
            login = "not logged in"
        }
        print("  \(b.target): \(login)")
    }
}

/// `_with-slot DIR MAX TARGET CMD...`, used by relay.sh: takes one of MAX lock files in DIR (waiting
/// if all are taken), runs CMD while holding it and exits with CMD's status. The kernel drops the
/// lock when this process exits, so a crash can't leave a slot taken. (CMD can't hold the lock
/// itself: ssh closes all inherited file descriptors at startup.)
func withSlot(_ args: [String]) -> Never {
    guard args.count >= 4, let max = Int(args[1]), max > 0 else { fail("usage: _with-slot DIR MAX TARGET CMD...") }
    let (dir, target, cmd) = (args[0], args[2], Array(args[3...]))
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var waited = 0
    while true {
        for i in 1...max {
            let fd = open("\(dir)/\(i).lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0 { runHoldingSlot(cmd) }
            if fd >= 0 { close(fd) }
        }
        if waited == 0 {
            FileHandle.standardError.write(Data("bridgectl: all \(max) \(target) sessions are in use; waiting for one to finish...\n".utf8))
        }
        waited += 1
        if waited > 3000 { fail("gave up waiting for a free \(target) session") }
        usleep(200_000)
    }
}

/// Runs `cmd` with our stdio (and terminal), passes on termination signals, and exits like it did.
func runHoldingSlot(_ cmd: [String]) -> Never {
    var pid: pid_t = 0
    let argv = cmd.map { strdup($0) } + [nil]
    let rc = posix_spawn(&pid, cmd[0], nil, nil, argv, environ)
    guard rc == 0 else { fail("couldn't run \(cmd[0]): \(String(cString: strerror(rc)))") }
    let child = pid
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGHUP, SIGINT, SIGQUIT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { kill(child, sig) }
        source.resume()
        sources.append(source)
    }
    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0 && errno == EINTR {}
    let signal = status & 0x7f
    exit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "status" : args.removeFirst()
if command == "_with-slot" { withSlot(args) }

do {
    switch command {
    case "status":
        status()
    case "add":
        guard let target = args.first, !target.hasPrefix("-") else { fail("missing cluster\n\n\(usage)") }
        var relay: String?, alias: String?
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--from" where i + 1 < args.count: relay = args[i + 1]; i += 2
            case "--as" where i + 1 < args.count: alias = args[i + 1]; i += 2
            default: fail("unexpected argument '\(args[i])'\n\n\(usage)")
            }
        }
        guard let relay else { fail("missing --from <relay>\n\n\(usage)") }
        print("Setting up \(relay)…")
        let b = try Provisioner.add(target: target, relay: relay, alias: alias)
        Notify.post(Notify.reload)
        print("Added \(b.name). On \(b.relay), `ssh \(b.alias)` now reaches \(b.target) through this Mac.")
        requireApp()
    case "remove":
        let b = bridge(args.first)
        let warning = try Provisioner.remove(b.name)
        Notify.post(Notify.reload)
        print("Removed \(b.name).")
        if let warning { print("Warning: \(warning)") }
    case "pause", "resume":
        let b = bridge(args.first)
        try Provisioner.setPaused(b.name, command == "pause")
        Notify.post(Notify.reload)
        print(command == "pause" ? "Paused \(b.name)." : "Resumed \(b.name).")
        requireApp()
    case "login":
        guard let target = args.first else { fail("missing cluster\n\n\(usage)") }
        Notify.post(Notify.login, target)
        print("Asked BridgeCtl to log into \(target); answer the dialog if one appears.")
        requireApp()
    case "reconnect":
        if let name = args.first { _ = bridge(name) }
        Notify.post(Notify.reconnect, args.first)
        requireApp()
    case "test":
        let b = bridge(args.first)
        let r = SSH.remote(b.relay, "ssh -n -o ConnectTimeout=15 \(b.alias) hostname", timeout: 40)
        if r.ok { print("OK: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))") } else { fail(r.message) }
    case "help", "-h", "--help":
        print(usage)
    default:
        fail("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    fail(error.localizedDescription)
}
