import AppKit
import BridgeCore
import SwiftUI

struct StatusIcon: View {
    @ObservedObject var manager: BridgeManager

    var body: some View {
        Image(systemName: manager.healthy || manager.config.bridges.allSatisfy(\.paused) ? "network" : "network.slash")
    }
}

struct MenuContent: View {
    @ObservedObject var manager: BridgeManager

    var body: some View {
        if manager.config.bridges.isEmpty {
            Text("No bridges yet")
        }
        ForEach(manager.config.bridges) { bridge in
            Menu("\(dot(bridge))  \(bridge.target) via \(bridge.relay)") {
                Text(tunnelText(bridge))
                Text(loginText(bridge.target))
                Text("On \(bridge.relay): ssh \(bridge.alias)")
                Divider()
                Button("Test Connection") { test(bridge) }
                Button("Log In to \(bridge.target) Now") { manager.logIn(bridge.target) }
                    .disabled(bridge.paused)
                Button("Reconnect Tunnel") { manager.reconnect(bridge) }
                    .disabled(bridge.paused)
                Button(bridge.paused ? "Resume" : "Pause") { manager.setPaused(bridge, !bridge.paused) }
                Divider()
                Button("Remove…") { remove(bridge) }
            }
        }
        if !manager.sshdUp {
            Text("⚠️ Local sshd isn't running (see logs)")
        }
        Divider()
        Button("Add Bridge…") { AddBridgeWindow.show(manager) }
        Button("Open Logs Folder") { NSWorkspace.shared.open(Paths.logs) }
        Toggle("Launch at Login", isOn: Binding(get: { manager.launchAtLogin }, set: { manager.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit BridgeCtl") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func dot(_ b: Bridge) -> String {
        if b.paused { return "⏸" }
        let tunnel = manager.tunnels[b.name]
        switch manager.logins[b.target] {
        case .loggedIn: return tunnel == .up ? "🟢" : (tunnel == .connecting ? "🟡" : "🔴")
        case .loggingIn, .checking, .none: return "🟡"
        default: return "🔴"
        }
    }

    private func tunnelText(_ b: Bridge) -> String {
        switch manager.tunnels[b.name] ?? .connecting {
        case .paused: return "Paused"
        case .connecting: return "Tunnel to \(b.relay): connecting…"
        case .up: return "Tunnel to \(b.relay): connected"
        case .down(let why): return "Tunnel to \(b.relay): down, retrying (\(why.prefix(70)))"
        }
    }

    private func loginText(_ target: String) -> String {
        switch manager.logins[target] {
        case .loggedIn: return "\(target): logged in"
        case .loggingIn: return "\(target): waiting for you to log in (see the dialog)"
        case .snoozed(let until):
            return "\(target): not logged in, will ask again at \(until.formatted(date: .omitted, time: .shortened))"
        case .unreachable: return "\(target): can't reach it from this Mac"
        case .checking, .none: return "\(target): checking…"
        }
    }

    private func test(_ b: Bridge) {
        DispatchQueue.global().async {
            let r = SSH.remote(b.relay, "ssh -n -o ConnectTimeout=15 \(b.alias) hostname", timeout: 40)
            DispatchQueue.main.async {
                if r.ok {
                    Alerts.show("\(b.name) works", "On \(b.relay), `ssh \(b.alias) hostname` returned \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).")
                } else {
                    Alerts.show("\(b.name) isn't working", r.message)
                }
            }
        }
    }

    private func remove(_ b: Bridge) {
        guard Alerts.confirm("Remove \(b.target) via \(b.relay)?",
                             "`ssh \(b.alias)` will stop working on \(b.relay). Its key and Host entry there are deleted.",
                             button: "Remove") else { return }
        DispatchQueue.global().async {
            let result = Result { try Provisioner.remove(b.name) }
            DispatchQueue.main.async {
                manager.reload()
                switch result {
                case .success(let warning?): Alerts.show("Removed \(b.name), with a problem", warning)
                case .success(nil): break
                case .failure(let error): Alerts.show("Couldn't remove \(b.name)", error.localizedDescription)
                }
            }
        }
    }
}
