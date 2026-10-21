import Foundation

/// Everything BridgeCtl keeps on disk lives under ~/.bridgectl.
public enum Paths {
    public static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let support = home.appendingPathComponent(".bridgectl")

    public static let config = support.appendingPathComponent("config.json")
    public static let status = support.appendingPathComponent("status.json")
    public static let relayScript = support.appendingPathComponent("relay.sh")

    public static let sshd = support.appendingPathComponent("sshd")
    public static let hostKey = sshd.appendingPathComponent("host_ed25519")
    public static let sshdConfig = sshd.appendingPathComponent("sshd_config")
    public static let authorizedKeys = sshd.appendingPathComponent("authorized_keys")
    public static let sshdPid = sshd.appendingPathComponent("sshd.pid")

    public static let logs = support.appendingPathComponent("logs")
    public static let run = support.appendingPathComponent("run")
    public static let appLock = run.appendingPathComponent("app.lock")

    /// The `bridgectl` CLI: this executable when running as the CLI, else the one inside the app bundle.
    public static var cli: String {
        let me = Bundle.main.executableURL?.resolvingSymlinksInPath()
        if let me, me.lastPathComponent == "bridgectl" { return me.path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bridgectl").path
    }

    public static func log(_ name: String) -> URL { logs.appendingPathComponent("\(name).log") }
    public static func pidFile(_ name: String) -> URL { run.appendingPathComponent("\(name).pid") }
    /// Pid of a bridge's sshd session on the relay (the process holding its forwarded port).
    public static func relaySessionFile(_ bridge: String) -> URL { run.appendingPathComponent("\(bridge).relay-session") }

    /// Creates the directory layout, private to this user (sshd's StrictModes requires that).
    public static func ensure() {
        for dir in [support, sshd, logs, run] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
        }
    }
}
