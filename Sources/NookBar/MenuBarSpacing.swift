// SPDX-License-Identifier: GPL-3.0-or-later
// Preference keys, base value, and offset range follow Ice's spacing manager,
// copyright (C) 2024 Jordan Baird. See THIRD_PARTY_NOTICES.md.
import AppKit
@preconcurrency import NativeMenuBar

struct MenuBarSpacingValues: Codable, Equatable {
    static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    var spacing: Data?
    var padding: Data?
    var values: [Data?] { [spacing, padding] }
    init(offset: Int) throws {
        guard (-16...16).contains(offset), offset.isMultiple(of: 2) else { throw Failure.offset }
        let data = offset == 0 ? nil : try PropertyListSerialization.data(fromPropertyList: NSNumber(value: 16 + offset), format: .binary, options: 0)
        spacing = data; padding = data
    }
    init(domain: CFString = kCFPreferencesAnyApplication) throws {
        let data = try Self.keys.map { key -> Data? in
            guard let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { return nil }
            return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        spacing = data[0]; padding = data[1]
    }
    var offset: Int? {
        if spacing == nil && padding == nil { return 0 }
        guard spacing == padding, let spacing,
              let value = try? PropertyListSerialization.propertyList(from: spacing, options: [], format: nil) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == Double(value.intValue),
              (0...32).contains(value.intValue), value.intValue.isMultiple(of: 2) else { return nil }
        return value.intValue - 16
    }
    private func write(domain: CFString) throws {
        for (key, data) in zip(Self.keys, values) {
            let value = try data.map { try PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { throw Failure.write }
        guard try Self(domain: domain) == self else { throw Failure.write }
    }
    func apply(domain: CFString = kCFPreferencesAnyApplication) throws {
        let previous = try Self(domain: domain)
        do { try write(domain: domain) }
        catch { try? previous.write(domain: domain); throw error }
    }
    enum Failure: LocalizedError {
        case offset, write
        var errorDescription: String? {
            switch self {
            case .offset: "Choose a spacing offset from −16 to +16 in steps of 2."
            case .write: "macOS did not save both spacing preferences. The previous values were restored where possible."
            }
        }
    }
}

@MainActor
final class MenuBarSpacing: ObservableObject {
    @Published var draft = 0.0
    @Published private(set) var applied: Int?
    @Published private(set) var isDefault = true
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var canRestoreOriginal = false
    private let defaults: UserDefaults
    private let backupKey = "SpacingOriginalValues"
    var onBeginRelaunch: (() -> Bool)?
    var onEndRelaunch: (() -> Void)?
    init(defaults: UserDefaults) { self.defaults = defaults; refresh() }
    var currentLabel: String {
        guard let applied else { return "Custom system spacing" }
        return isDefault ? "macOS default" : "Offset \(applied > 0 ? "+" : "")\(applied)"
    }
    var canApply: Bool { !isBusy && (applied != Int(draft) || (draft == 0 && !isDefault)) }
    func refresh() {
        do {
            let values = try MenuBarSpacingValues()
            applied = values.offset; isDefault = values.spacing == nil && values.padding == nil
            draft = Double(applied ?? 0)
        }
        catch { status = error.localizedDescription }
        canRestoreOriginal = defaults.data(forKey: backupKey).flatMap { try? JSONDecoder().decode(MenuBarSpacingValues.self, from: $0) } != nil
    }
    func apply(offset: Int) {
        guard !isBusy else { return }
        do {
            let values = try MenuBarSpacingValues(offset: offset)
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(try JSONEncoder().encode(MenuBarSpacingValues()), forKey: backupKey)
            }
            try values.apply()
            refresh()
            status = "Spacing saved. Relaunch menu bar apps to load the change. Some system icons may require logging out and back in."
        } catch { status = error.localizedDescription; refresh() }
    }
    func restoreOriginal() {
        guard !isBusy, let data = defaults.data(forKey: backupKey) else { return }
        do {
            try JSONDecoder().decode(MenuBarSpacingValues.self, from: data).apply()
            defaults.removeObject(forKey: backupKey)
            refresh()
            status = "Your previous spacing preferences were restored. Relaunch menu bar apps to load them."
        } catch { status = error.localizedDescription }
    }
    func relaunchMenuApps() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard AXIsProcessTrusted() else { status = "Enable Accessibility access to discover menu bar apps."; return }
        guard onBeginRelaunch?() != false else { status = "Close open menus and wait for icon movement or hiding to finish, then try again."; return }
        defer { onEndRelaunch?() }
        try? await Task.sleep(for: .milliseconds(300))
        let bundles = Set(NSScreen.screens.flatMap { NBMenuBarEntries(HiddenBar.captureFrame(for: $0)).map(\.bundle) })
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard let bundle = $0.bundleIdentifier else { return false }
            return bundles.contains(bundle) && !bundle.hasPrefix("com.apple.") && $0 != .current && $0.bundleURL != nil
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        guard !apps.isEmpty else { status = "No third-party menu bar apps were found. Show the menu bar and try again."; return }
        let alert = NSAlert()
        alert.messageText = "Relaunch menu bar apps?"
        alert.informativeText = "Selected apps will be asked to quit, then reopened in the background. Save your work first. Apps that do not quit within five seconds will stay open; you can relaunch them manually."
        alert.addButton(withTitle: "Relaunch Selected"); alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(280, apps.count * 26)))
        scroll.hasVerticalScroller = true
        let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 5
        var buttons: [NSButton] = []
        for app in apps {
            let button = NSButton(checkboxWithTitle: app.localizedName ?? app.bundleIdentifier ?? "App", target: nil, action: nil)
            button.state = .on; list.addArrangedSubview(button); buttons.append(button)
        }
        scroll.documentView = list; list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { status = "Relaunch cancelled. The saved spacing is unchanged."; return }
        let chosen = zip(apps, buttons).filter { $0.1.state == .on }.map(\.0)
        guard !chosen.isEmpty else { status = "No apps selected. Nothing was relaunched."; return }
        status = "Relaunching \(chosen.count) menu bar \(chosen.count == 1 ? "app" : "apps")…"
        var failures: [String] = []
        let quitting = chosen.filter { app in
            if app.isTerminated || app.terminate() { return true }
            failures.append(app.localizedName ?? app.bundleIdentifier ?? "App")
            return false
        }
        let deadline = Date().addingTimeInterval(5)
        while quitting.contains(where: { !$0.isTerminated }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for app in quitting { if let failure = await reopen(app) { failures.append(failure) } }
        failures.sort()
        status = failures.isEmpty ? "Selected apps relaunched. Check the menu bar; some system icons may require logging out and back in." : "Relaunch these apps manually: \(failures.joined(separator: ", "))."
    }
    private func reopen(_ app: NSRunningApplication) async -> String? {
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        guard let url = app.bundleURL, let bundle = app.bundleIdentifier else { return name }
        guard app.isTerminated else { return name }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.addsToRecentItems = false; configuration.promptsUserIfNeeded = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); return nil }
        catch { return name }
    }
}
