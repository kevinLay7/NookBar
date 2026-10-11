import AppKit
@preconcurrency import ApplicationServices
import Darwin
@preconcurrency import NativeMenuBar

struct Compatibility: Codable {
    let macOS: String
    let accessibilityGranted: Bool
    let frameworkAvailable: Bool
    let configurationAvailable: Bool
    let activationAvailable: Bool
    let invalidationAvailable: Bool

    init() {
        macOS = ProcessInfo.processInfo.operatingSystemVersionString
        accessibilityGranted = AXIsProcessTrusted()
        // Keep the framework loaded for the lifetime of the process.
        frameworkAvailable = dlopen(
            "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
            RTLD_LAZY
        ) != nil
        let configuration: AnyClass? = NSClassFromString("MBAssessmentModeConfiguration")
        let assertion: AnyClass? = NSClassFromString("MBAssessmentModeAssertion")
        configurationAvailable = configuration?.instancesRespond(
            to: NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        ) ?? false
        activationAvailable = assertion?.instancesRespond(
            to: NSSelectorFromString("activateWithConfiguration:completionHandler:")
        ) ?? false
        invalidationAvailable = assertion?.instancesRespond(
            to: NSSelectorFromString("invalidate")
        ) ?? false
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

@MainActor
private final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var accessibilityItem: NSMenuItem?
    private let visibility = NBVisibilityController()
    private var selected = Set(UserDefaults.standard.stringArray(forKey: "HiddenApps") ?? [])
    private var apps: [(bundle: String, name: String)] = []
    private var appWindow: NSWindow?
    private var appList: NSStackView?
    private var messageLabel: NSTextField?
    private var accessButton: NSButton?
    private var toggleItem: NSMenuItem?
    private var isPending = false
    private var operation = 0
    private var monitor: Timer?
    private var runningBundles = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var status = "Choose apps to tuck away."
    private var settingsMenu: NSMenu?
    private let hiddenBar = HiddenBar()
    private var cachedIcons: [HiddenBar.Icon] = []
    private var cachedScreenFrame: CGRect?
    private var menuWatch: Timer?
    private var emptyBarMonitor: Any?
    private var requestedBarAnchor: (NSRect, NSScreen)?
    private var controlPanel: NSPanel?
    private var nativeControlAnchor: (NSRect, NSScreen)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NookBar.Control"
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "NookBar")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "NookBar — click for hidden icons; right-click for settings"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let title = NSMenuItem(title: "NookBar — Development Preview", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "Hide Selected Apps", action: #selector(toggleVisibility), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)
        let manage = NSMenuItem(title: "Choose Apps…", action: #selector(chooseApps), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        let restore = NSMenuItem(title: "Show All Apps", action: #selector(showAll), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        menu.addItem(.separator())
        let accessibility = NSMenuItem(title: "Request Accessibility Access…", action: #selector(requestAccessibility), keyEquivalent: "")
        accessibility.target = self
        accessibilityItem = accessibility
        menu.addItem(accessibility)
        let diagnostics = NSMenuItem(title: "Check Compatibility…", action: #selector(checkCompatibility), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NookBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        settingsMenu = menu
        item.menu = menu
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        hiddenBar.onSelect = { [weak self] icon in self?.openHiddenIcon(icon) }
        hiddenBar.isControlWindow = { [weak self] window in
            guard let self else { return false }
            return window === self.controlPanel || window === self.statusItem?.button?.window
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { await self.runSelfTest() }
            return
        }
        promptForAccessibility()
        emptyBarMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
                let point = NSEvent.mouseLocation
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                guard NBIsEmptyMenuBarPoint(CGPoint(x: point.x, y: top - point.y)) else { return }
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                    let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
                    self.requestedBarAnchor = (NSRect(x: point.x, y: screen.frame.maxY - max(barHeight, NSStatusBar.system.thickness), width: 1, height: 1), screen)
                }
                self.showHiddenBar()
            }
        }
        selected.remove(Bundle.main.bundleIdentifier ?? "com.codenest.nookbar")
        refreshApps()
        runningBundles = currentBundles()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore(message: "Apps restored for sleep or lock.") }
            })
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bundles = self.currentBundles()
                if (self.visibility.active || self.isPending) && (!AXIsProcessTrusted() || bundles != self.runningBundles) {
                    self.restore(message: "Apps restored because access or running apps changed.")
                }
                self.runningBundles = bundles
                if self.visibility.active { self.ensureControl() }
            }
        }
        if selected.isEmpty || CommandLine.arguments.contains("--choose-apps") { chooseApps() }
        if CommandLine.arguments.contains("--show-bar") {
            Task { try? await Task.sleep(for: .milliseconds(500)); showHiddenBar() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        accessibilityItem?.title = trusted ? "Accessibility Access Granted" : "Request Accessibility Access…"
        accessibilityItem?.isEnabled = !trusted
        toggleItem?.title = visibility.active ? "Show Hidden Apps" : "Hide Selected Apps (\(selected.count))"
        toggleItem?.isEnabled = visibility.active || (trusted && !selected.isEmpty && !isPending)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chooseApps()
        return true
    }

    private func currentBundles() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter {
            $0 != "com.codenest.nookbar.controller"
        })
    }

    private func snapshot() -> (counts: [String: Int], error: String?) {
        let result = NBMenuBarSnapshot()
        return (result["occurrences"] as? [String: Int] ?? [:], result["error"] as? String)
    }

    private func refreshApps() {
        guard !visibility.active && !isPending else { return }
        let result = snapshot()
        if let error = result.error { setStatus(error); return }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        apps = result.counts.keys.filter { !$0.hasPrefix("com.apple.") && $0 != own }.map { bundle in
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle }
            return (bundle, app?.localizedName ?? bundle)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if apps.isEmpty { setStatus("No third-party menu bar apps found. Try Refresh Apps.") }
    }

    private func setStatus(_ message: String) {
        NSLog("NookBar STATUS: %@", message)
        status = message
        messageLabel?.stringValue = message
    }

    private func restore(message: String) {
        operation += 1
        menuWatch?.invalidate()
        menuWatch = nil
        hiddenBar.close(notify: false)
        controlPanel?.orderOut(nil)
        controlPanel = nil
        cachedIcons = []
        cachedScreenFrame = nil
        visibility.restore()
        isPending = false
        setStatus(message)
    }

    @objc private func showAll() { restore(message: "All apps are shown.") }

    @objc private func statusClicked(_ sender: NSButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            hiddenBar.close()
            if let menu = settingsMenu, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: sender)
            }
        } else if hiddenBar.isVisible { hiddenBar.close() }
        else { showHiddenBar() }
    }

    private func barAnchor() -> (NSRect, NSScreen)? {
        if let panel = controlPanel, panel.isVisible, let screen = panel.screen { return (panel.frame, screen) }
        guard let button = statusItem?.button, let window = button.window, let screen = window.screen else { return nil }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        if let entry = NBMenuBarEntries(HiddenBar.captureFrame(for: screen)).first(where: { $0.bundle == own }) {
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let frame = NSRect(x: entry.frame.minX, y: top - entry.frame.maxY, width: entry.frame.width, height: entry.frame.height)
            return (frame, screen)
        }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return screen.frame.intersects(frame) ? (frame, screen) : nativeControlAnchor
    }

    private func ensureControl() {
        guard visibility.active, let (original, screen) = nativeControlAnchor else { return }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        guard snapshot().counts[own] == nil else {
            controlPanel?.orderOut(nil); controlPanel = nil; return
        }
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let expected = CGRect(x: original.minX, y: top - original.maxY, width: original.width, height: original.height)
        let slot = NBEmptyStatusSlot(HiddenBar.captureFrame(for: screen), expected)
        guard !slot.isNull else { restore(message: "NookBar's control could not be kept visible. Apps have been restored."); return }
        // macOS 27 can leave our slot empty under assessment mode. Draw a
        // clickable control only in that vacant slot, never over another icon.
        let frame = NSRect(x: slot.midX - 12, y: top - slot.midY - 12, width: 24, height: 24)
        if let controlPanel { controlPanel.setFrame(frame, display: true); return }
        let panel = ControlPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NookBar Control"
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        effect.material = .menu; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 5; effect.layer?.masksToBounds = true
        let control = NSButton(title: "N", target: self, action: #selector(statusClicked))
        control.font = .systemFont(ofSize: 14, weight: .semibold)
        control.frame = effect.bounds; control.isBordered = false
        control.setAccessibilityLabel("NookBar")
        control.toolTip = "NookBar — click for hidden icons; right-click for settings"
        control.sendAction(on: [.leftMouseUp, .rightMouseUp])
        effect.addSubview(control); panel.contentView = effect
        controlPanel = panel; panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--test-control") { panel.makeKeyAndOrderFront(nil) }
    }

    @objc private func showHiddenBar() {
        guard !isPending, let (anchor, screen) = requestedBarAnchor ?? barAnchor() else { return }
        requestedBarAnchor = nil
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard !selected.isEmpty else { chooseApps(); return }
        guard CGPreflightScreenCaptureAccess() else {
            let alert = NSAlert()
            alert.messageText = "Allow NookBar to read menu bar icons"
            alert.informativeText = "Screen Recording access is required to display the original icons in the hidden bar. NookBar samples only their menu bar region and keeps the images in memory."
            alert.addButton(withTitle: "Enable Screen Recording…")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = CGRequestScreenCaptureAccess()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
        if visibility.active && !cachedIcons.isEmpty && cachedScreenFrame == screen.frame {
            hiddenBar.show(icons: cachedIcons, anchor: anchor, screen: screen)
            return
        }
        // Restore for one fresh capture, then hide again before displaying the strip.
        restore(message: "Loading hidden icons…")
        let generation = operation
        isPending = true
        let targets = selected.intersection(currentBundles())
        Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let icons = try await HiddenBar.capture(bundles: targets, screen: screen)
                guard generation == operation else { return }
                let error = await activate(Array(targets))
                guard generation == operation else { return }
                isPending = false
                if let error { restore(message: error); return }
                cachedIcons = icons
                cachedScreenFrame = screen.frame
                setStatus("Click NookBar to open hidden icons. Right-click for settings.")
                hiddenBar.show(icons: icons, anchor: anchor, screen: screen)
                try? await Task.sleep(for: .seconds(1))
                if generation == operation { ensureControl() }
            } catch {
                guard generation == operation else { return }
                restore(message: error.localizedDescription)
                let alert = NSAlert(); alert.messageText = "Could not load hidden icons"
                alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }

    private func openHiddenIcon(_ icon: HiddenBar.Icon) {
        guard let (_, screen) = barAnchor() else { showAll(); return }
        operation += 1
        let generation = operation
        menuWatch?.invalidate()
        isPending = true
        let remaining = selected.intersection(currentBundles()).subtracting([icon.bundle])
        Task { [self] in
            let error: String?
            if remaining.isEmpty { visibility.restore(); error = nil }
            else { error = await activate(Array(remaining)) }
            guard generation == operation else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == operation else { return }
            isPending = false
            guard error == nil, NBPressMenuBarEntry(icon.bundle, UInt(icon.index), HiddenBar.captureFrame(for: screen)) else {
                restore(message: error ?? "Could not open this menu bar item. Apps have been restored.")
                return
            }
            let started = Date()
            menuWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, generation == self.operation else { return }
                    // Give a menu time to appear; keep the original item visible while it is open.
                    guard Date().timeIntervalSince(started) > 1, !NBMenuIsOpen(icon.bundle) else { return }
                    self.menuWatch?.invalidate(); self.menuWatch = nil
                    self.visibility.restore()
                    self.toggleVisibility()
                }
            }
        }
    }

    private func activate(_ bundles: [String]) async -> String? {
        runningBundles = currentBundles()
        if let anchor = barAnchor() { nativeControlAnchor = anchor }
        return await withCheckedContinuation { continuation in
            visibility.hideBundles(bundles) { success, message in
                continuation.resume(returning: success ? nil : (message ?? "Could not hide apps."))
            }
        }
    }

    @objc private func toggleVisibility() {
        if visibility.active || isPending { showAll(); return }
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let targets = selected.intersection(currentBundles()).filter { $0 != own && !$0.hasPrefix("com.apple.") }
        guard !targets.isEmpty else { chooseApps(); return }
        operation += 1
        let generation = operation
        runningBundles = currentBundles()
        isPending = true
        setStatus("Hiding selected apps…")
        Task {
            let error = await activate(Array(targets))
            guard generation == operation else { return }
            isPending = false
            if let error { restore(message: error); return }
            setStatus("Selected apps are hidden. Click NookBar to open their icons; right-click for settings.")
            try? await Task.sleep(for: .seconds(1))
            if generation == operation { ensureControl() }
        }
    }

    @objc private func chooseApps() {
        showAll()
        refreshApps()
        if appWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "NookBar — Choose Apps"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 420, height: 360)
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
            ])
            let intro = NSTextField(wrappingLabelWithString: "Select the apps you want to tuck away. Their icons share visibility across displays.")
            stack.addArrangedSubview(intro)
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let access = NSButton(title: "Enable Accessibility Access…", target: self, action: #selector(requestAccessibility))
            access.isHidden = AXIsProcessTrusted()
            stack.addArrangedSubview(access)
            accessButton = access
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 8
            list.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            scroll.documentView = list
            list.translatesAutoresizingMaskIntoConstraints = false
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            appList = list
            let selectionButtons = NSStackView()
            selectionButtons.spacing = 8
            for (title, action) in [("Refresh Apps", #selector(refreshAppWindow)), ("Select All", #selector(selectAllApps)), ("Clear Selection", #selector(clearSelection))] {
                selectionButtons.addArrangedSubview(NSButton(title: title, target: self, action: action))
            }
            stack.addArrangedSubview(selectionButtons)
            let buttons = NSStackView()
            buttons.spacing = 8
            for (title, action) in [("Hide Selected", #selector(toggleVisibility)), ("Show All", #selector(showAll)), ("Hidden Icons", #selector(showHiddenBar))] {
                buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
            }
            stack.addArrangedSubview(buttons)
            let message = NSTextField(wrappingLabelWithString: status)
            message.textColor = .secondaryLabelColor
            stack.addArrangedSubview(message)
            message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            messageLabel = message
            let note = NSTextField(wrappingLabelWithString: "macOS may also hide some system icons, such as Focus. Show All or quit NookBar to restore them.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            appWindow = window
            window.center()
        }
        populateAppList()
        accessButton?.isHidden = AXIsProcessTrusted()
        appWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func populateAppList() {
        guard let list = appList else { return }
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for app in apps {
            let checkbox = NSButton(checkboxWithTitle: app.name, target: self, action: #selector(selectApp(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier(app.bundle)
            checkbox.state = selected.contains(app.bundle) ? .on : .off
            checkbox.toolTip = app.bundle
            list.addArrangedSubview(checkbox)
        }
        if apps.isEmpty { list.addArrangedSubview(NSTextField(labelWithString: "No apps found")) }
    }

    @objc private func selectApp(_ sender: NSButton) {
        guard let bundle = sender.identifier?.rawValue else { return }
        showAll()
        if sender.state == .on { selected.insert(bundle) } else { selected.remove(bundle) }
        UserDefaults.standard.set(selected.sorted(), forKey: "HiddenApps")
        setStatus("\(selected.count) app(s) selected. Click Hide Selected.")
    }

    @objc private func refreshAppWindow() {
        showAll()
        refreshApps()
        populateAppList()
        accessButton?.isHidden = AXIsProcessTrusted()
    }

    @objc private func selectAllApps() {
        showAll()
        selected = Set(apps.map(\.bundle))
        UserDefaults.standard.set(selected.sorted(), forKey: "HiddenApps")
        populateAppList()
        setStatus("\(selected.count) app(s) selected. Click Hide Selected.")
    }

    @objc private func clearSelection() {
        showAll()
        selected.removeAll()
        UserDefaults.standard.set([], forKey: "HiddenApps")
        populateAppList()
        setStatus("Choose apps to tuck away.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        if let emptyBarMonitor { NSEvent.removeMonitor(emptyBarMonitor) }
        menuWatch?.invalidate()
        hiddenBar.close(notify: false)
        controlPanel?.orderOut(nil)
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        visibility.restore()
    }

    private func runSelfTest() async {
        var report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString]
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        defer { visibility.restore() }
        try? await Task.sleep(for: .seconds(2))
        let before = snapshot()
        report["before"] = before.counts
        if let screen = NSScreen.screens.first {
            let entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen))
            let keys = entries.map { "\($0.bundle):\($0.frame)" }
            let discovered = entries.filter { $0.bundle == own }.count == 1 && Set(keys).count == keys.count
            report["entryDiscovery"] = discovered
            if CGPreflightScreenCaptureAccess() {
                do {
                    let icons = try await HiddenBar.capture(bundles: [own], screen: screen)
                    report["iconCapture"] = icons.count == 1 && icons[0].image.size.width > 0
                } catch { report["iconCapture"] = false; report["captureError"] = error.localizedDescription }
            }
        }
        var passed = false
        if let error = before.error { report["error"] = error }
        else if (before.counts[own] ?? 0) == 0 { report["error"] = "Test icon was not discovered; refusing to hide." }
        else {
            let error = await activate([own])
            try? await Task.sleep(for: .seconds(2))
            let during = snapshot()
            report["during"] = during.counts
            report["activationError"] = error ?? NSNull()
            visibility.restore()
            try? await Task.sleep(for: .seconds(2))
            let after = snapshot()
            report["after"] = after.counts
            let hidden = during.error == nil && during.counts[own] == nil && !during.counts.isEmpty
            let restored = after.error == nil && after.counts[own] == before.counts[own]
            let preserved = before.counts.filter { !$0.key.hasPrefix("com.apple.") && $0.key != own }.allSatisfy {
                during.counts[$0.key] == $0.value
            }
            report["hidden"] = hidden
            report["restored"] = restored
            report["otherAppsPreserved"] = preserved
            passed = error == nil && hidden && restored && preserved
            if let other = before.counts.keys.sorted().first(where: { !$0.hasPrefix("com.apple.") && $0 != own }) {
                let otherError = await activate([other])
                try? await Task.sleep(for: .seconds(2))
                let otherSnapshot = snapshot()
                report["ownIconPreserved"] = otherError == nil && otherSnapshot.counts[own] == before.counts[own]
                ensureControl()
                let controlAvailable = otherSnapshot.counts[own] == before.counts[own] || controlPanel?.isVisible == true
                report["ownControlAvailable"] = controlAvailable
                report["otherTarget"] = other
                visibility.restore()
                controlPanel?.orderOut(nil); controlPanel = nil
                try? await Task.sleep(for: .milliseconds(500))
                passed = passed && otherError == nil && otherSnapshot.counts[other] == nil && controlAvailable
            }
            if passed {
                var repeated = true
                for _ in 0..<2 {
                    let repeatError = await activate([own])
                    try? await Task.sleep(for: .seconds(1))
                    let repeatHidden = snapshot()
                    visibility.restore()
                    try? await Task.sleep(for: .seconds(1))
                    let repeatShown = snapshot()
                    repeated = repeated && repeatError == nil && repeatHidden.error == nil &&
                        repeatHidden.counts[own] == nil && repeatShown.error == nil && repeatShown.counts[own] == before.counts[own]
                }
                report["repeatedToggles"] = repeated
                let cancelled: Bool = await withCheckedContinuation { continuation in
                    visibility.hideBundles([own]) { success, _ in continuation.resume(returning: !success) }
                    visibility.restore()
                }
                try? await Task.sleep(for: .seconds(1))
                let afterCancel = snapshot()
                let cancellationPassed = cancelled && !visibility.active && afterCancel.error == nil && afterCancel.counts[own] == before.counts[own]
                report["cancellationRestored"] = cancellationPassed
                passed = passed && repeated && cancellationPassed
            }
        }
        report["passed"] = passed
        if let discovered = report["entryDiscovery"] as? Bool { passed = passed && discovered }
        if let captured = report["iconCapture"] as? Bool { passed = passed && captured }
        report["passed"] = passed
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            } catch { NSLog("NookBar self-test report failed: %@", error.localizedDescription) }
        }
        NSLog("NookBar SELF-TEST: %@", passed ? "PASS" : "FAIL")
        NSApp.terminate(nil)
    }

    private func promptForAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        // The system prompt is asynchronous; its return value is the current grant.
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        promptForAccessibility()
        let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        if !NSWorkspace.shared.open(settings) {
            let alert = NSAlert()
            alert.messageText = "Enable Accessibility Access"
            alert.informativeText = "Open System Settings → Privacy & Security → Accessibility and enable NookBar."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func checkCompatibility() {
        let alert = NSAlert()
        alert.messageText = "NookBar Compatibility"
        do {
            alert.informativeText = try Compatibility().json() + "\n\nChoose Apps from the tray menu, select apps, then click Hide Selected. Show All Apps restores them."
        } catch {
            alert.informativeText = "Could not format diagnostics: \(error.localizedDescription)"
        }
        let needsAccess = !AXIsProcessTrusted()
        if needsAccess {
            alert.informativeText += "\n\nNookBar needs Accessibility access to discover and control menu bar apps. Enable NookBar in System Settings."
            alert.addButton(withTitle: "Request Accessibility Access…")
            alert.addButton(withTitle: "Not Now")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && needsAccess {
            requestAccessibility()
        }
    }
}

if CommandLine.arguments.contains("--snapshot") {
    do {
        let data = try JSONSerialization.data(withJSONObject: NBMenuBarSnapshot(), options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fputs("NookBar snapshot failed: \(error)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.contains("--diagnose") {
    do {
        print(try Compatibility().json())
    } catch {
        fputs("NookBar diagnostics failed: \(error)\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
