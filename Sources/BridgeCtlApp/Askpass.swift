import AppKit

/// When ssh needs an answer (Duo, host key confirmation, ...) it runs this app's executable as its
/// SSH_ASKPASS with the prompt as the only argument; we show it in a dialog and print the answer.
enum Askpass {
    static let modeVariable = "BRIDGECTL_ASKPASS"
    static let targetVariable = "BRIDGECTL_TARGET"
    private static let giveUpAfter: TimeInterval = 300

    static var isRequested: Bool { ProcessInfo.processInfo.environment[modeVariable] == "1" }

    static func run() -> Never {
        let prompt = CommandLine.arguments.dropFirst().first ?? "Response:"
        let target = ProcessInfo.processInfo.environment[targetVariable] ?? "ssh"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let alert = NSAlert()
        alert.messageText = "BridgeCtl needs you to log into \(target)"
        alert.informativeText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Not Now")
        let secret = prompt.range(of: "password|passphrase|PIN", options: [.regularExpression, .caseInsensitive]) != nil
        let field = secret ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        // Duo asks "Passcode or option (1-3)"; option 1 is Duo Push, so Enter just sends a push.
        if prompt.localizedCaseInsensitiveContains("option") { field.stringValue = "1" }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.window.level = .floating

        // An unanswered prompt shouldn't block reconnecting forever.
        let timer = Timer(timeInterval: giveUpAfter, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        app.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { exit(1) }
        print(field.stringValue)
        exit(0)
    }
}
