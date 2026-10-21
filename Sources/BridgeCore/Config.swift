import Foundation

/// One bridge: clients on `relay` run `ssh <alias>` and land on `target`, using this Mac's
/// already-authenticated (e.g. Duo) ControlMaster connection to `target`.
public struct Bridge: Codable, Hashable, Identifiable {
    /// Unique id, used in file names and in the relay's config markers (e.g. "neuronic-whitney").
    public var name: String
    /// ssh host this Mac logs into, with ControlMaster/ControlPath set up (e.g. "neuronic").
    public var target: String
    /// ssh host where the clients run, reachable from this Mac without prompts (e.g. "whitney").
    public var relay: String
    /// Host name clients use on the relay (usually the same as `target`).
    public var alias: String
    /// Port on the relay's 127.0.0.1 that is forwarded back to this Mac's private sshd.
    public var remotePort: Int
    /// The relay's client key for this bridge; this Mac's sshd only lets it relay to `target`.
    public var publicKey: String
    /// Paused bridges keep their setup but run no tunnel.
    public var paused: Bool

    public var id: String { name }
}

public struct BridgeConfig: Codable {
    /// Port of the private sshd on this Mac's 127.0.0.1 (only reachable through the tunnels).
    public var sshdPort: Int
    /// After a login prompt is cancelled or fails, wait this long before asking again.
    public var snoozeMinutes: Int
    /// Most relayed sessions at once per target. Servers refuse sessions beyond their MaxSessions
    /// (often 10) on one connection; extra clients wait instead. Leaves room for your own sessions.
    public var maxSessions: Int
    public var bridges: [Bridge]

    public init(sshdPort: Int, snoozeMinutes: Int = 20, maxSessions: Int = 8, bridges: [Bridge] = []) {
        self.sshdPort = sshdPort; self.snoozeMinutes = snoozeMinutes; self.maxSessions = maxSessions
        self.bridges = bridges
    }

    // Settings added later default when missing, so older config files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sshdPort = try c.decode(Int.self, forKey: .sshdPort)
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 20
        maxSessions = try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 8
        bridges = try c.decodeIfPresent([Bridge].self, forKey: .bridges) ?? []
    }

    public static func load() -> BridgeConfig {
        if let data = try? Data(contentsOf: Paths.config),
           let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
            return config
        }
        // Saved right away so the app and the CLI agree on the (random) sshd port.
        let config = BridgeConfig(sshdPort: Int.random(in: 40000...49999))
        if !FileManager.default.fileExists(atPath: Paths.config.path) { try? config.save() }
        return config
    }

    public func save() throws {
        Paths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.config, options: .atomic)
        chmod(Paths.config.path, 0o600)
    }

    public func bridge(named name: String) -> Bridge? { bridges.first { $0.name == name } }
}
