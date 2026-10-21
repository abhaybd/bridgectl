import Foundation

public enum SSH {
    public static let path = "/usr/bin/ssh"

    /// The effective ssh options for `host` (`ssh -G`), keyed by lowercase option name.
    public static func options(for host: String) -> [String: String] {
        var result = [String: String]()
        for line in Shell.run(path, ["-G", host], timeout: 10).stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, result[String(parts[0])] == nil { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// Pid of the running ControlMaster for `host`, or nil if there is none.
    public static func masterPID(_ host: String) -> Int32? {
        let r = Shell.run(path, ["-O", "check", host], timeout: 10)
        guard r.ok, let range = r.stderr.range(of: #"pid=\d+"#, options: .regularExpression) else { return nil }
        return Int32(r.stderr[range].dropFirst(4))
    }

    /// Runs `command` on `host` without any prompts (fails instead of asking).
    @discardableResult
    public static func remote(_ host: String, _ command: String, input: String? = nil,
                              timeout: TimeInterval = 60) -> ProcResult {
        Shell.run(path, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command],
                  input: input, timeout: timeout)
    }

    /// Whether `host`'s ssh port accepts TCP connections (assumed true when it goes through a proxy).
    public static func reachable(_ host: String) -> Bool {
        let o = options(for: host)
        if let proxy = o["proxyjump"] ?? o["proxycommand"], proxy != "none" { return true }
        guard let hostname = o["hostname"] else { return false }
        return Shell.run("/usr/bin/nc", ["-z", "-G", "5", hostname, o["port"] ?? "22"], timeout: 10).ok
    }

    /// Concrete host names from `Host` lines in ~/.ssh/config (patterns are skipped).
    public static func configuredHosts() -> [String] {
        let file = Paths.home.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var hosts = [String]()
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.first?.lowercased() == "host" else { continue }
            for w in words.dropFirst() where !w.contains(where: { "*?!".contains($0) }) && !hosts.contains(String(w)) {
                hosts.append(String(w))
            }
        }
        return hosts
    }
}
