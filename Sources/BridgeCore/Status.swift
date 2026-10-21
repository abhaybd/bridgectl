import Foundation

/// What the app last saw, written to ~/.bridgectl/status.json for the CLI.
public struct StatusSnapshot: Codable {
    public struct BridgeStatus: Codable {
        public var name, target, relay, alias: String
        public var paused: Bool
        /// "connecting", "up", "down" or "paused".
        public var tunnel: String
        public var detail: String?

        public init(name: String, target: String, relay: String, alias: String, paused: Bool,
                    tunnel: String, detail: String? = nil) {
            self.name = name; self.target = target; self.relay = relay; self.alias = alias
            self.paused = paused; self.tunnel = tunnel; self.detail = detail
        }
    }

    public struct TargetStatus: Codable {
        public var target: String
        /// "checking", "logged-in", "logging-in", "snoozed" or "unreachable".
        public var state: String
        public var masterPID: Int32?
        public var snoozedUntil: Date?

        public init(target: String, state: String, masterPID: Int32? = nil, snoozedUntil: Date? = nil) {
            self.target = target; self.state = state; self.masterPID = masterPID; self.snoozedUntil = snoozedUntil
        }
    }

    public var updated: Date
    public var sshdUp: Bool
    public var bridges: [BridgeStatus]
    public var targets: [TargetStatus]

    public init(updated: Date, sshdUp: Bool, bridges: [BridgeStatus], targets: [TargetStatus]) {
        self.updated = updated; self.sshdUp = sshdUp; self.bridges = bridges; self.targets = targets
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Paths.status, options: .atomic)
    }

    public static func load() -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }
}

/// Messages from the CLI to the running app.
public enum Notify {
    public static let reload = Notification.Name("com.abhaybd.bridgectl.reload")
    /// object: the target to log into now.
    public static let login = Notification.Name("com.abhaybd.bridgectl.login")
    /// object: a bridge name, or nil for all.
    public static let reconnect = Notification.Name("com.abhaybd.bridgectl.reconnect")

    public static func post(_ name: Notification.Name, _ object: String? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}

/// Only one app instance may run; the CLI uses the same lock to tell whether it's running.
public enum AppLock {
    private static var fd: Int32 = -1

    public static func acquire() -> Bool {
        Paths.ensure()
        // O_CLOEXEC: children (notably daemonized ssh masters) must not inherit and hold the lock.
        fd = open(Paths.appLock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    public static func isHeldElsewhere() -> Bool {
        let f = open(Paths.appLock.path, O_RDWR | O_CLOEXEC)
        guard f >= 0 else { return false }
        defer { close(f) }
        if flock(f, LOCK_EX | LOCK_NB) == 0 { flock(f, LOCK_UN); return false }
        return true
    }
}
