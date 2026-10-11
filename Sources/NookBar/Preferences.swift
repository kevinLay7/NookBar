import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class Preferences {
    enum Flag: String, CaseIterable {
        case useBar, showOnClick, showOnHover, showOnScroll, autoRehide, secondaryMenu, hideOnLaunch
        var title: String {
            switch self {
            case .useBar: "Show hidden icons in a separate bar"
            case .showOnClick: "Open by clicking empty menu bar space"
            case .showOnHover: "Open by hovering over empty menu bar space"
            case .showOnScroll: "Show or hide by scrolling in the menu bar"
            case .autoRehide: "Automatically rehide"
            case .secondaryMenu: "Right-click empty menu bar space for settings"
            case .hideOnLaunch: "Hide selected apps when NookBar starts"
            }
        }
    }
    enum Location: String, CaseIterable { case dynamic, pointer, icon }
    enum Rehide: String, CaseIterable { case smart, timed, focusedApp }
    enum ShortcutAction: Int, CaseIterable {
        case toggle = 1, search = 2, alwaysHidden = 3, barMode = 4
        var title: String {
            switch self {
            case .toggle: "Show or hide hidden icons"
            case .search: "Search menu bar icons"
            case .alwaysHidden: "Show or hide always-hidden icons"
            case .barMode: "Toggle the hidden icon bar"
            }
        }
    }

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "useBar": true, "showOnClick": true, "showOnHover": false, "showOnScroll": true,
            "autoRehide": true, "secondaryMenu": true, "hideOnLaunch": true,
            "barLocation": Location.dynamic.rawValue, "rehideStrategy": Rehide.smart.rawValue,
            "hoverDelay": 0.2, "rehideInterval": 15.0
        ])
    }
    func enabled(_ flag: Flag) -> Bool { defaults.bool(forKey: flag.rawValue) }
    var location: Location { Location(rawValue: defaults.string(forKey: "barLocation") ?? "") ?? .dynamic }
    var rehide: Rehide { Rehide(rawValue: defaults.string(forKey: "rehideStrategy") ?? "") ?? .smart }
    var hoverDelay: Double { bounded("hoverDelay", range: 0...5, fallback: 0.2) }
    var rehideInterval: Double { bounded("rehideInterval", range: 1...300, fallback: 15) }
    private func bounded(_ key: String, range: ClosedRange<Double>, fallback: Double) -> Double {
        let value = defaults.double(forKey: key)
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
    func shortcut(_ action: ShortcutAction) -> Shortcut? {
        guard let data = defaults.data(forKey: "shortcut.\(action.rawValue)") else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) }, forKey: "shortcut.\(action.rawValue)")
    }
    func shouldRehide(elapsed: Double, inside: Bool, pointerEntered: Bool) -> Bool {
        guard enabled(.autoRehide) else { return false }
        switch rehide {
        case .smart: return pointerEntered && !inside && elapsed >= hoverDelay
        case .timed: return elapsed >= rehideInterval
        case .focusedApp: return false // Workspace activation notifications perform this transition.
        }
    }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt
    let key: String
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var valid: Bool {
        keyCode <= 127 && !key.isEmpty && !flags.intersection([.command, .control, .option]).isEmpty
    }
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        valid && self.keyCode == UInt32(keyCode) && self.flags == flags.intersection([.command, .control, .option, .shift])
    }
    var title: String {
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value + key.uppercased()
    }
}

@MainActor
final class PreferencesWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let preferences: Preferences
    private let appearance: MenuBarAppearance
    private var tabs: NSTabView?
    private var window: NSWindow?
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let shortcutFeedback = NSTextField(wrappingLabelWithString: "")
    private var loginButton: NSButton?
    private var flagButtons: [Preferences.Flag: NSButton] = [:]
    var isVisible: Bool { window?.isVisible == true }
    var onChange: (() -> Void)?
    var onRecording: ((Bool) -> Void)?

    init(preferences: Preferences, appearance: MenuBarAppearance) { self.preferences = preferences; self.appearance = appearance }
    func show(tab: String? = nil) {
        if window == nil { build() }
        if let tab { tabs?.selectTabViewItem(withIdentifier: tab) }
        for (flag, button) in flagButtons { button.state = preferences.enabled(flag) ? .on : .off }
        loginButton?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if SMAppService.mainApp.status == .requiresApproval {
            feedback.stringValue = "Launch at login needs approval in System Settings → General → Login Items."
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func report(_ message: String) { feedback.stringValue = message; shortcutFeedback.stringValue = message }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NookBar Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let tabs = NSTabView(frame: window.contentView!.bounds.insetBy(dx: 18, dy: 18))
        self.tabs = tabs
        tabs.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(tabs)
        let general = makeStack()
        heading("Startup", in: general)
        let login = NSButton(checkboxWithTitle: "Launch NookBar at login", target: self, action: #selector(changeLogin))
        loginButton = login
        general.addArrangedSubview(login)
        checkbox(.hideOnLaunch, in: general)
        heading("Hidden icons", in: general)
        checkbox(.useBar, in: general)
        popup("Bar location", key: "barLocation", values: [("Dynamic", "dynamic"), ("Mouse pointer", "pointer"), ("NookBar icon", "icon")], in: general)
        heading("Open the bar", in: general)
        for flag in [Preferences.Flag.showOnClick, .showOnHover, .showOnScroll, .secondaryMenu] { checkbox(flag, in: general) }
        number("Hover delay (seconds)", key: "hoverDelay", value: preferences.hoverDelay, range: 0...5, step: 0.1, in: general)
        heading("Rehide", in: general)
        checkbox(.autoRehide, in: general)
        popup("Strategy", key: "rehideStrategy", values: [("Smart", "smart"), ("After a delay", "timed"), ("When the focused app changes", "focusedApp")], in: general)
        number("Rehide delay (seconds)", key: "rehideInterval", value: preferences.rehideInterval, range: 1...300, step: 1, in: general)
        let note = NSTextField(wrappingLabelWithString: "Smart rehide waits until you leave the bar. Open menus remain usable until they close. Settings are saved as you change them.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        general.addArrangedSubview(note)
        note.widthAnchor.constraint(equalToConstant: 470).isActive = true
        feedback.textColor = .secondaryLabelColor
        general.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalToConstant: 470).isActive = true
        tab("General", content: general, in: tabs)
        let shortcuts = makeStack()
        heading("Keyboard shortcuts", in: shortcuts)
        let help = NSTextField(wrappingLabelWithString: "Click a shortcut, then press a key with Command, Control, or Option. Escape cancels; Delete clears it. Shortcuts work in other apps.")
        help.widthAnchor.constraint(equalToConstant: 470).isActive = true
        shortcuts.addArrangedSubview(help)
        for action in Preferences.ShortcutAction.allCases {
            let row = NSStackView()
            row.spacing = 18
            row.addArrangedSubview(NSTextField(labelWithString: action.title))
            let recorder = ShortcutRecorder(title: "", target: nil, action: nil)
            recorder.target = recorder; recorder.action = #selector(ShortcutRecorder.beginRecording)
            recorder.shortcut = preferences.shortcut(action)
            recorder.onRecording = { [weak self] in self?.onRecording?($0) }
            recorder.onChange = { [weak self] shortcut in
                guard let self else { return }
                preferences.setShortcut(shortcut, for: action)
                onChange?()
            }
            recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
            row.addArrangedSubview(recorder)
            shortcuts.addArrangedSubview(row)
        }
        shortcutFeedback.textColor = .secondaryLabelColor
        shortcutFeedback.widthAnchor.constraint(equalToConstant: 470).isActive = true
        shortcuts.addArrangedSubview(shortcutFeedback)
        tab("Shortcuts", content: shortcuts, in: tabs)
        let appearanceTab = NSTabViewItem(identifier: "Appearance"); appearanceTab.label = "Appearance"
        appearanceTab.view = NSHostingView(rootView: AppearanceEditor(manager: appearance))
        tabs.addTabViewItem(appearanceTab)
        self.window = window
        window.center()
    }
    func windowWillClose(_ notification: Notification) { appearance.preview = nil }
    private func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return stack
    }
    private func tab(_ title: String, content: NSStackView, in tabs: NSTabView) {
        let view = NSView()
        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor)
        ])
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = view
        tabs.addTabViewItem(item)
    }
    private func heading(_ title: String, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
    }
    private func checkbox(_ flag: Preferences.Flag, in stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: flag.title, target: self, action: #selector(changeFlag))
        button.identifier = .init(flag.rawValue)
        button.state = preferences.enabled(flag) ? .on : .off
        flagButtons[flag] = button
        stack.addArrangedSubview(button)
    }
    private func popup(_ title: String, key: String, values: [(String, String)], in stack: NSStackView) {
        let row = NSStackView(); row.spacing = 12
        row.addArrangedSubview(NSTextField(labelWithString: title))
        let popup = NSPopUpButton()
        popup.identifier = .init(key); popup.target = self; popup.action = #selector(changeChoice)
        for (label, raw) in values { popup.addItem(withTitle: label); popup.lastItem?.representedObject = raw }
        if let raw = preferences.defaults.string(forKey: key), let index = values.firstIndex(where: { $0.1 == raw }) { popup.selectItem(at: index) }
        row.addArrangedSubview(popup); stack.addArrangedSubview(row)
    }
    private func number(_ title: String, key: String, value: Double, range: ClosedRange<Double>, step: Double, in stack: NSStackView) {
        let row = NSStackView(); row.spacing = 12
        row.addArrangedSubview(NSTextField(labelWithString: title))
        let field = NSTextField(string: String(format: "%.1f", value))
        field.identifier = .init(key); field.target = self; field.action = #selector(changeNumber)
        field.delegate = self
        let formatter = NumberFormatter(); formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound); formatter.maximumFractionDigits = 1
        field.formatter = formatter
        field.widthAnchor.constraint(equalToConstant: 65).isActive = true
        let stepper = NSStepper(); stepper.minValue = range.lowerBound; stepper.maxValue = range.upperBound
        stepper.increment = step; stepper.doubleValue = value
        stepper.identifier = .init(key); stepper.target = self; stepper.action = #selector(changeNumber)
        row.addArrangedSubview(field); row.addArrangedSubview(stepper); stack.addArrangedSubview(row)
    }
    @objc private func changeFlag(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        preferences.defaults.set(sender.state == .on, forKey: key); onChange?()
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { changeNumber(field) }
    }
    @objc private func changeChoice(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue, let raw = sender.selectedItem?.representedObject as? String else { return }
        preferences.defaults.set(raw, forKey: key); onChange?()
    }
    @objc private func changeNumber(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        let value = sender.doubleValue
        preferences.defaults.set(value, forKey: key)
        if let row = sender.superview as? NSStackView {
            for control in row.arrangedSubviews.compactMap({ $0 as? NSControl }) where control.identifier == sender.identifier { control.doubleValue = value }
        }
        onChange?()
    }
    @objc private func changeLogin(_ sender: NSButton) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            feedback.stringValue = SMAppService.mainApp.status == .requiresApproval
                ? "Approve NookBar in System Settings → General → Login Items."
                : "Launch at login updated."
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            feedback.stringValue = error.localizedDescription
        }
    }
}

@MainActor
private final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { title = shortcut?.title ?? "Record Shortcut…" } }
    var onChange: ((Shortcut?) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self); onRecording?(true)
    }
    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }
    override func performClick(_ sender: Any?) {
        beginRecording()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; onChange?(nil); finish(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let value = Shortcut(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue,
                             key: event.charactersIgnoringModifiers ?? "")
        guard value.valid else { NSSound.beep(); return }
        shortcut = value; onChange?(value); finish()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func resignFirstResponder() -> Bool { if recording { finish() }; return super.resignFirstResponder() }
    private func finish() { recording = false; title = shortcut?.title ?? "Record Shortcut…"; onRecording?(false) }
}
