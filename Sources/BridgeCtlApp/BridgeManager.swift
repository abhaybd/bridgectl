import AppKit
import BridgeCore
import Network

enum TunnelState: Equatable {
    case paused, connecting, up
    case down(String)
}

/// Runs everything: the private sshd, one reverse tunnel per bridge and one LoginKeeper per target.
/// All its properties are used on the main thread.
final class BridgeManager: ObservableObject {
    static let shared = BridgeManager()

    @Published private(set) var config = BridgeConfig.load()
    @Published private(set) var tunnels: [String: TunnelState] = [:]
    @Published private(set) var logins: [String: LoginState] = [:]
    @Published private(set) var sshdUp = false
    @Published private(set) var launchAtLogin = LoginItem.isEnabled

    private var sshd: Supervised?
    private var runners: [String: (bridge: Bridge, tunnel: Supervised)] = [:]
    private var keepers: [String: LoginKeeper] = [:]
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var lastPath: String?
    private var pendingReconnect: DispatchWorkItem?
    private var portFailures: [String: Int] = [:]
    private var movingPort: Set<String> = []

    var healthy: Bool {
        let active = config.bridges.filter { !$0.paused }
        return sshdUp && active.allSatisfy { b in
            tunnels[b.name] == .up && { if case .loggedIn = logins[b.target] { return true }; return false }()
        }
    }

    func start() {
        Paths.ensure()
        Supervised.killOrphans()
        do { try Provisioner.writeLocalFiles(config) } catch { NSLog("BridgeCtl: \(error.localizedDescription)") }
        let sshd = Supervised(name: "sshd", exe: "/usr/sbin/sshd", args: ["-D", "-e", "-f", Paths.sshdConfig.path],
                              upMarker: "Server listening", retryDelay: 5) { [weak self] state in
            DispatchQueue.main.async { self?.sshdUp = state == .up; self?.publish() }
        }
        self.sshd = sshd
        sshd.start()
        sync()

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.keepers.values.forEach { $0.check() }
        }
        // After sleep or a network change, connections are usually dead even if ssh hasn't noticed yet.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.scheduleReconnect(after: 3)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let fingerprint = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPath = fingerprint }
                if self.lastPath != nil, self.lastPath != fingerprint, path.status == .satisfied {
                    self.scheduleReconnect(after: 3)
                }
            }
        }
        pathMonitor.start(queue: .global())

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notify.reload, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        center.addObserver(forName: Notify.login, object: nil, queue: .main) { [weak self] n in
            if let target = n.object as? String { self?.logIn(target) }
        }
        center.addObserver(forName: Notify.reconnect, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            if let name = n.object as? String { self.runners[name]?.tunnel.restart() } else { self.reconnectAll() }
        }
    }

    func shutdown() {
        runners.values.forEach { $0.tunnel.stop() }
        sshd?.stop()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Re-reads the config (after the CLI or the UI changed it) and applies it.
    func reload() {
        let oldPort = config.sshdPort
        config = BridgeConfig.load()
        do { try Provisioner.writeLocalFiles(config) } catch { NSLog("BridgeCtl: \(error.localizedDescription)") }
        if config.sshdPort != oldPort {
            // sshd reads its port at startup, and every tunnel forwards to it: restart them all.
            sshd?.restart()
            runners.values.forEach { $0.tunnel.stop() }
            runners = [:]
        }
        sync()
    }

    func logIn(_ target: String) { keepers[target]?.check(force: true) }

    func reconnect(_ bridge: Bridge) { runners[bridge.name]?.tunnel.restart() }

    func reconnectAll() {
        runners.values.forEach { $0.tunnel.restart() }
        keepers.values.forEach { $0.check() }
    }

    func setPaused(_ bridge: Bridge, _ paused: Bool) {
        do { try Provisioner.setPaused(bridge.name, paused) } catch { Alerts.show("Couldn't update \(bridge.name)", error.localizedDescription) }
        reload()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        pendingReconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconnectAll() }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Starts/stops tunnels and keepers to match the config.
    private func sync() {
        let active = config.bridges.filter { !$0.paused }
        for (name, runner) in runners where !active.contains(runner.bridge) {
            runner.tunnel.stop()
            runners[name] = nil
        }
        for bridge in active where runners[bridge.name] == nil {
            runners[bridge.name] = (bridge, makeTunnel(bridge))
            runners[bridge.name]?.tunnel.start()
        }
        tunnels = Dictionary(uniqueKeysWithValues: config.bridges.map { b in
            (b.name, b.paused ? .paused : (tunnels[b.name].flatMap { $0 == .paused ? nil : $0 } ?? .connecting))
        })

        let targets = Set(active.map(\.target))
        for target in keepers.keys where !targets.contains(target) { keepers[target] = nil }
        for target in targets {
            if let keeper = keepers[target] { keeper.snoozeMinutes = config.snoozeMinutes; continue }
            let keeper = LoginKeeper(target: target, snoozeMinutes: config.snoozeMinutes) { [weak self] state in
                DispatchQueue.main.async { self?.logins[target] = state; self?.publish() }
            }
            keepers[target] = keeper
            logins[target] = .checking
            keeper.check()
        }
        logins = logins.filter { targets.contains($0.key) }
        publish()
    }

    private func makeTunnel(_ b: Bridge) -> Supervised {
        let forward = "127.0.0.1:\(b.remotePort):127.0.0.1:\(config.sshdPort)"
        let sessionFile = Paths.relaySessionFile(b.name)
        // The remote command reports the relay sshd session serving this tunnel (its pid and start
        // time), then just waits for the connection to end.
        let report = #"echo "\#(Self.sessionMarker)$PPID $(ps -o lstart= -p $PPID)"; exec cat >/dev/null"#
        return Supervised(
            name: "tunnel-\(b.name)", exe: SSH.path,
            args: ["-v", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=15",
                   "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                   "-o", "ControlMaster=no", "-o", "ControlPath=none", "-R", forward, b.relay, report],
            upMarker: "remote forward success", retryDelay: 10,
            before: {
                // When a tunnel's connection dies without a clean disconnect (sleep, network change),
                // the relay's sshd can keep that session, and the forwarded port, for hours.
                guard let record = try? String(contentsOf: sessionFile, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: sessionFile)
                Self.killRelaySession(relay: b.relay, record: record, log: Log(Paths.log("tunnel-\(b.name)")))
            },
            onStdout: { line in
                guard line.hasPrefix(Self.sessionMarker) else { return }
                try? String(line.dropFirst(Self.sessionMarker.count)).write(to: sessionFile, atomically: true, encoding: .utf8)
            }
        ) { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.runners[b.name]?.bridge == b else { return }
                switch state {
                case .starting: self.tunnels[b.name] = .connecting
                case .up:
                    self.tunnels[b.name] = .up
                    self.portFailures[b.name] = 0
                case .down(let why):
                    self.tunnels[b.name] = .down(why)
                    if why.contains("remote port forwarding failed") { self.portInUse(b) }
                case .stopped: break
                }
                self.publish()
            }
        }
    }

    private static let sessionMarker = "BRIDGECTL_SESSION="

    /// Kills the relay sshd session in `record` ("PID START"), if it's still that same process.
    private static func killRelaySession(relay: String, record: String, log: Log) {
        let parts = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let pid = Int(parts[0]) else { return }
        let start = parts[1].trimmingCharacters(in: .whitespaces)
        let script = """
            p=\(pid); s=\(Shell.quote(start))
            if [ "$(ps -o lstart= -p $p 2>/dev/null | sed 's/^ *//;s/ *$//')" = "$s" ]; then
              kill $p; sleep 1; kill -0 $p 2>/dev/null && kill -9 $p; echo KILLED
            fi
            true
            """
        let r = SSH.remote(relay, script, timeout: 20)
        if r.stdout.contains("KILLED") { log.write("closed the previous tunnel's leftover session on \(relay) (pid \(pid))") }
    }

    /// The bridge's port on the relay is taken, usually by a dead session we couldn't identify.
    /// After a few tries, move the bridge to a fresh port instead of waiting hours for it to clear.
    private func portInUse(_ b: Bridge) {
        portFailures[b.name, default: 0] += 1
        guard portFailures[b.name, default: 0] >= 3, !movingPort.contains(b.name) else { return }
        movingPort.insert(b.name)
        let log = Log(Paths.log("tunnel-\(b.name)"))
        DispatchQueue.global().async {
            let result = Result { try Provisioner.movePort(b.name) }
            DispatchQueue.main.async {
                self.movingPort.remove(b.name)
                self.portFailures[b.name] = 0
                switch result {
                case .success(let port): log.write("port \(b.remotePort) on \(b.relay) stays taken; moved the bridge to port \(port)")
                case .failure(let error): log.write("couldn't move to a new port: \(error.localizedDescription)")
                }
                self.reload()
            }
        }
    }

    /// Writes status.json for the CLI.
    private func publish() {
        let bridges = config.bridges.map { b -> StatusSnapshot.BridgeStatus in
            var tunnel = "connecting", detail: String?
            switch tunnels[b.name] ?? .connecting {
            case .paused: tunnel = "paused"
            case .connecting: tunnel = "connecting"
            case .up: tunnel = "up"
            case .down(let why): tunnel = "down"; detail = why
            }
            return .init(name: b.name, target: b.target, relay: b.relay, alias: b.alias, paused: b.paused,
                         tunnel: tunnel, detail: detail)
        }
        let targets = logins.keys.sorted().map { t -> StatusSnapshot.TargetStatus in
            switch logins[t]! {
            case .checking: return .init(target: t, state: "checking")
            case .loggedIn(let pid): return .init(target: t, state: "logged-in", masterPID: pid)
            case .loggingIn: return .init(target: t, state: "logging-in")
            case .snoozed(let until): return .init(target: t, state: "snoozed", snoozedUntil: until)
            case .unreachable: return .init(target: t, state: "unreachable")
            }
        }
        StatusSnapshot(updated: Date(), sshdUp: sshdUp, bridges: bridges, targets: targets).save()
    }
}

enum Alerts {
    static func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
