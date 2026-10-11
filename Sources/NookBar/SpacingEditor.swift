import SwiftUI

struct SpacingEditor: View {
    @ObservedObject var manager: MenuBarSpacing
    var body: some View {
        Form {
            Section("Menu Bar Item Spacing") {
                Text("Current: \(manager.currentLabel)").foregroundStyle(.secondary)
                HStack {
                    Slider(value: $manager.draft, in: -16...16, step: 2).accessibilityLabel("Menu bar spacing offset")
                    Text(manager.draft == 0 ? "Default" : String(format: "%+.0f", manager.draft)).monospacedDigit().frame(width: 64)
                }
                HStack {
                    Text("Compact"); Spacer(); Text("Spacious")
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply") { manager.apply(offset: Int(manager.draft)) }.disabled(!manager.canApply)
                    Button("macOS Default") { manager.apply(offset: 0) }.disabled(manager.isBusy || manager.isDefault)
                }
                Text("Apply saves the system spacing. Relaunch menu bar apps to see the change now. Some system icons may require logging out and back in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Relaunch Apps") {
                Button("Relaunch Menu Bar Apps…") { Task { await manager.relaunchMenuApps() } }.disabled(manager.isBusy)
                Text("Choose which apps to restart. NookBar restores all icons during discovery and resumes your requested hidden state afterward.")
                    .font(.caption).foregroundStyle(.secondary)
                if manager.isBusy { ProgressView().controlSize(.small) }
            }
            if manager.canRestoreOriginal {
                Section("Restore") {
                    Button("Restore Previous Spacing") { manager.restoreOriginal() }.disabled(manager.isBusy)
                    Text("Restore the system preferences that were present before NookBar first changed spacing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !manager.status.isEmpty { Section { Text(manager.status).font(.caption).foregroundStyle(.secondary) } }
        }.formStyle(.grouped).onAppear { manager.refresh() }
    }
}
