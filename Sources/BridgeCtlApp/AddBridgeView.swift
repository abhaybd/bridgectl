import AppKit
import BridgeCore
import SwiftUI

enum AddBridgeWindow {
    private static var window: NSWindow?

    static func show(_ manager: BridgeManager) {
        window?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Add Bridge"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: AddBridgeView(manager: manager) { w.close() })
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct AddBridgeView: View {
    @ObservedObject var manager: BridgeManager
    let close: () -> Void

    @State private var target = ""
    @State private var relay = ""
    @State private var alias = ""
    @State private var busy = false
    @State private var error: String?
    private let hosts = SSH.configuredHosts()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lets programs on a relay host reach a cluster through this Mac's logged-in (e.g. Duo) connection.")
                .fixedSize(horizontal: false, vertical: true)
            field("Cluster", "ssh host this Mac logs into, e.g. cluster", $target)
            field("Relay", "ssh host the programs run on, e.g. workstation", $relay)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name on relay").font(.headline)
                TextField(target.isEmpty ? "same as the cluster" : target, text: $alias)
                Text("Programs on the relay will run `ssh <name>`.").font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Setting up \(relay)…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(busy || target.isEmpty || relay.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field(_ title: String, _ hint: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            HStack(spacing: 4) {
                TextField(hint, text: text)
                if !hosts.isEmpty {
                    Menu {
                        ForEach(hosts, id: \.self) { h in Button(h) { text.wrappedValue = h } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hosts from ~/.ssh/config")
                }
            }
        }
    }

    private func add() {
        busy = true
        error = nil
        let (t, r, a) = (target.trimmingCharacters(in: .whitespaces), relay.trimmingCharacters(in: .whitespaces),
                         alias.trimmingCharacters(in: .whitespaces))
        DispatchQueue.global().async {
            let result = Result { try Provisioner.add(target: t, relay: r, alias: a) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success:
                    manager.reload()
                    close()
                case .failure(let e):
                    error = e.localizedDescription
                }
            }
        }
    }
}
