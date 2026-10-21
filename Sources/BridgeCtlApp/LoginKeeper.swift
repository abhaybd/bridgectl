import BridgeCore
import Foundation

enum LoginState: Equatable {
    case checking
    case loggedIn(pid: Int32)
    case loggingIn
    case snoozed(until: Date)
    case unreachable
}

/// Keeps this Mac logged into one target: when its ControlMaster is gone it opens a new one,
/// asking the user (Duo etc.) through the app's askpass dialog.
final class LoginKeeper {
    let target: String
    var snoozeMinutes: Int

    private let queue: DispatchQueue
    private let onState: (LoginState) -> Void
    private let lock = NSLock()
    private var scheduled = false
    private var scheduledForce = false
    private var snoozedUntil: Date?  // only touched on `queue`

    /// Gives up on a login nobody answers (e.g. the Mac went to sleep mid-prompt).
    private static let loginTimeout: TimeInterval = 360

    init(target: String, snoozeMinutes: Int, onState: @escaping (LoginState) -> Void) {
        self.target = target
        self.snoozeMinutes = snoozeMinutes
        self.onState = onState
        queue = DispatchQueue(label: "login-\(target)")
    }

    /// Checks the login soon; `force` skips any snooze and asks right away if needed.
    func check(force: Bool = false) {
        lock.lock()
        scheduledForce = scheduledForce || force
        let alreadyQueued = scheduled
        scheduled = true
        lock.unlock()
        if alreadyQueued { return }
        queue.async { [self] in
            lock.lock()
            let force = scheduledForce
            scheduled = false
            scheduledForce = false
            lock.unlock()
            run(force: force)
        }
    }

    private func run(force: Bool) {
        if let pid = SSH.masterPID(target) {
            snoozedUntil = nil
            onState(.loggedIn(pid: pid))
            return
        }
        if force { snoozedUntil = nil }
        if let until = snoozedUntil, until > Date() { onState(.snoozed(until: until)); return }
        guard SSH.reachable(target) else { onState(.unreachable); return }
        onState(.loggingIn)
        if let pid = logIn() {
            onState(.loggedIn(pid: pid))
        } else {
            let until = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
            snoozedUntil = until
            onState(.snoozed(until: until))
        }
    }

    /// Opens a background ControlMaster (`ssh -fN`); prompts go to this app in askpass mode.
    private func logIn() -> Int32? {
        let log = Log(Paths.log("login-\(target)"))
        log.write("not logged into \(target); logging in")
        let args = ["-fN", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "BatchMode=no",
                    "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=4", "-o", "ConnectTimeout=15", target]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SSH.path)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging([
            "SSH_ASKPASS": Bundle.main.executablePath ?? CommandLine.arguments[0],
            "SSH_ASKPASS_REQUIRE": "force",
            Askpass.modeVariable: "1",
            Askpass.targetVariable: target,
        ]) { $1 }
        // Never pipes: the daemonized master keeps these open for as long as it lives.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log.handle
        p.standardError = log.handle
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch {
            log.write("couldn't run ssh: \(error.localizedDescription)")
            return nil
        }
        if exited.wait(timeout: .now() + Self.loginTimeout) == .timedOut {
            p.terminate()
            log.write("gave up waiting for the login")
            return nil
        }
        let master = SSH.masterPID(target)
        // If a master appeared elsewhere meanwhile (e.g. a manual `ssh`), ours fell back to a plain
        // connection with the same command line; close it, sparing the real master.
        let pattern = ([SSH.path] + args).joined(separator: " ")
        for line in Shell.run("/usr/bin/pgrep", ["-f", "-x", pattern], timeout: 5).stdout.split(separator: "\n") {
            if let pid = Int32(line), pid != master {
                kill(pid, SIGTERM)
                log.write("closed duplicate connection \(pid)")
            }
        }
        log.write(master != nil ? "logged in" : "login failed or was cancelled; asking again in \(snoozeMinutes) min")
        return master
    }
}
