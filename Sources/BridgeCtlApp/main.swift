import AppKit
import BridgeCore
import SwiftUI

signal(SIGPIPE, SIG_IGN)

// ssh runs this same executable as its SSH_ASKPASS to show login prompts.
if Askpass.isRequested { Askpass.run() }

// Exit 0 so launchd (KeepAlive on unsuccessful exit) doesn't keep relaunching a duplicate.
guard AppLock.acquire() else { exit(0) }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BridgeManager.shared.start()
        // launchd stops us with SIGTERM; shut the tunnels down cleanly instead of orphaning them.
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeManager.shared.shutdown()
    }
}

struct BridgeCtlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: .shared)
        } label: {
            StatusIcon(manager: .shared)
        }
        .menuBarExtraStyle(.menu)
    }
}

BridgeCtlApp.main()
