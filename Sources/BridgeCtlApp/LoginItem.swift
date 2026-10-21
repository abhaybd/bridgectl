import Foundation

/// Starts the app at login through a LaunchAgent, which also relaunches it if it crashes
/// (but not after Quit, which exits successfully).
enum LoginItem {
    static let label = "com.abhaybd.bridgectl"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    /// Takes effect at the next login; turning it off doesn't stop the running app.
    static func setEnabled(_ enabled: Bool) {
        guard enabled else { try? FileManager.default.removeItem(at: plist); return }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? CommandLine.arguments[0]],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0).write(to: plist)
    }
}
