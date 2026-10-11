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
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var accessibilityItem: NSMenuItem?
    private let visibility = NBVisibilityController()
    private let sections = AppSections()
    private var selected: Set<String> { sections.tucked }
    private var presentedSection: AppSections.Section = .hidden
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
    private let preferences = Preferences()
    private lazy var appearance = MenuBarAppearance(defaults: preferences.defaults)
    private lazy var preferencesWindow = PreferencesWindow(preferences: preferences, appearance: appearance)
    private let hotKeys = GlobalHotKeys()
    private var localBarMonitor: Any?
    private var localKeyMonitor: Any?
    private var recordingShortcut = false
    private var behaviorTimer: Timer?
    private var visibilityRequested = false
    private var nativeItemsRevealed = false
    private var presentationStarted: Date?
    private var hoverStarted: Date?
    private var hoverSuppressed = false
    private var emptyClickWasVisible = false
    private var temporaryBundle: String?
    private var cachedIncludesVisible = false
    private var pointerEnteredPresentation = false
    private var pointerLeftPresentation: Date?
    private var separatorLab: SeparatorLab?
    private lazy var arrangementWindow = ArrangementWindow()
    private var arrangingIcons = false

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
        let settings = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let appearanceItem = NSMenuItem(title: "Menu Bar Appearance…", action: #selector(showAppearance), keyEquivalent: "")
        appearanceItem.target = self; menu.addItem(appearanceItem)
        let arrange = NSMenuItem(title: "Arrange Menu Bar Icons…", action: #selector(showArrangement), keyEquivalent: "")
        arrange.target = self
        menu.addItem(arrange)
        let search = NSMenuItem(title: "Search Menu Bar Icons…", action: #selector(showIconSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        let always = NSMenuItem(title: "Always-Hidden Icons…", action: #selector(showAlwaysHidden), keyEquivalent: "")
        always.target = self
        menu.addItem(always)
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
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        hiddenBar.onSelect = { [weak self] icon in self?.openHiddenIcon(icon) }
        hiddenBar.isControlWindow = { [weak self] window in
            guard let self else { return false }
            return window === self.controlPanel || window === self.statusItem?.button?.window
        }
        hiddenBar.onClose = { [weak self] in
            self?.presentationStarted = nil
            self?.hoverSuppressed = true
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { await self.runSelfTest() }
            return
        }
        if CommandLine.arguments.contains("--separator-lab") {
            let lab = SeparatorLab(); separatorLab = lab; lab.show()
            return
        }
        promptForAccessibility()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseUp, .scrollWheel]
        emptyBarMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMenuBarEvent(event) }
        }
        localBarMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMenuBarEvent(event)
            return event
        }
        hotKeys.onAction = { [weak self] action in
            guard let self, !arrangingIcons else { return }
            switch action {
            case .search: showIconSearch()
            case .toggle: togglePresentation()
            case .alwaysHidden: togglePresentation(section: .alwaysHidden)
            case .barMode:
                preferences.defaults.set(!preferences.enabled(.useBar), forKey: "useBar")
                rehidePresentation()
                preferencesChanged()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !recordingShortcut, !event.isARepeat else { return event }
            for action in Preferences.ShortcutAction.allCases {
                if preferences.shortcut(action)?.matches(keyCode: event.keyCode, flags: event.modifierFlags) == true {
                    hotKeys.onAction?(action)
                    return nil
                }
            }
            return event
        }
        preferencesWindow.onChange = { [weak self] in self?.preferencesChanged() }
        preferencesWindow.onRecording = { [weak self] recording in
            guard let self else { return }
            recordingShortcut = recording
            if recording { hotKeys.clear() } else { preferencesChanged() }
        }
        arrangementWindow.onClose = { [weak self] in
            guard let self else { return }
            arrangingIcons = false
            if visibilityRequested { hideSelectedApps() }
        }
        appearance.start()
        preferencesChanged()
        refreshApps()
        runningBundles = currentBundles()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.arrangementWindow.close(); self?.restore(message: "Apps restored for sleep or lock.", clearIntent: false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.arrangementWindow.cancel(); self?.resumeVisibility() }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.preferences.enabled(.autoRehide), self.preferences.rehide == .focusedApp,
                      let bundle, bundle != Bundle.main.bundleIdentifier else { return }
                self.rehidePresentation()
            }
        })
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bundles = self.currentBundles()
                if (self.visibility.active || self.isPending) && !AXIsProcessTrusted() {
                    self.restore(message: "Apps restored because Accessibility access was removed.")
                } else if bundles != self.runningBundles && self.visibilityRequested && !self.isPending && !self.arrangingIcons {
                    self.cachedIcons = []
                    if let temporary = self.temporaryBundle, NBMenuIsOpen(temporary) {
                        self.runningBundles = bundles
                    } else if self.nativeItemsRevealed {
                        self.revealNativeSection(self.presentedSection)
                    } else { self.hideSelectedApps() }
                }
                self.runningBundles = bundles
                if self.visibility.active { self.ensureControl() }
            }
        }
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHoverAndRehide() }
        }
        if selected.isEmpty || CommandLine.arguments.contains("--choose-apps") { chooseApps() }
        if CommandLine.arguments.contains("--settings") { showPreferences() }
        else if CommandLine.arguments.contains("--appearance") { showAppearance() }
        else if CommandLine.arguments.contains("--arrange-icons") {
            visibilityRequested = preferences.enabled(.hideOnLaunch) && !selected.isEmpty
            showArrangement()
        }
        else if CommandLine.arguments.contains("--search") { showIconSearch() }
        else if CommandLine.arguments.contains("--show-bar") {
            Task { try? await Task.sleep(for: .milliseconds(500)); showHiddenBar() }
        } else if preferences.enabled(.hideOnLaunch), !selected.isEmpty,
                  !CommandLine.arguments.contains("--choose-apps") {
            visibilityRequested = true
            resumeVisibility()
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
        if arrangingIcons { arrangementWindow.show(); return true }
        if preferencesWindow.isVisible { preferencesWindow.show(); return true }
        togglePresentation()
        return true
    }

    private func currentBundles() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
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

    private func restore(message: String, clearIntent: Bool = true) {
        if clearIntent { visibilityRequested = false }
        nativeItemsRevealed = false
        presentationStarted = nil
        temporaryBundle = nil
        pointerLeftPresentation = nil
        operation += 1
        menuWatch?.invalidate()
        menuWatch = nil
        hiddenBar.close(notify: false)
        controlPanel?.orderOut(nil)
        controlPanel = nil
        cachedIcons = []
        cachedScreenFrame = nil
        cachedIncludesVisible = false
        visibility.restore()
        isPending = false
        setStatus(message)
    }

    @objc private func showAll() { restore(message: "All apps are shown.") }

    @objc private func showArrangement() {
        guard dismissTemporaryMenu() else { return }
        arrangingIcons = true
        restore(message: "All icons are visible while arranging.", clearIntent: false)
        arrangementWindow.show()
    }

    @objc private func showPreferences() { openPreferences() }
    @objc private func showAppearance() { openPreferences(tab: "Appearance") }
    private func openPreferences(tab: String? = nil) {
        let hadTemporaryMenu = temporaryBundle != nil
        guard !isPending, dismissTemporaryMenu() else { return }
        if arrangingIcons { arrangementWindow.close() }
        if hadTemporaryMenu && visibilityRequested { hideSelectedApps() }
        hiddenBar.close()
        preferencesWindow.show(tab: tab)
    }

    private func preferencesChanged() {
        if let error = hotKeys.update(preferences) { preferencesWindow.report(error) }
        else { preferencesWindow.report("Settings saved.") }
        hoverStarted = nil
    }

    private func pointerAnchor(_ point: NSPoint) -> (NSRect, NSScreen)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        let barHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return (NSRect(x: point.x, y: screen.frame.maxY - barHeight, width: 1, height: 1), screen)
    }

    private func presentationAnchor() -> (NSRect, NSScreen)? {
        switch preferences.location {
        case .dynamic: return requestedBarAnchor ?? barAnchor()
        case .pointer: return pointerAnchor(NSEvent.mouseLocation) ?? barAnchor()
        case .icon: return barAnchor()
        }
    }

    private func pointerInMenuBar(_ point: NSPoint) -> Bool {
        // Avoid Accessibility queries while the pointer is far from any menu bar.
        guard NSScreen.screens.contains(where: { $0.frame.contains(point) && $0.frame.maxY - point.y < 48 }) else { return false }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return !NBMenuBarFrameAtPoint(CGPoint(x: point.x, y: top - point.y)).isNull
    }

    private func isEmptyMenuPoint(_ point: NSPoint) -> Bool {
        guard pointerInMenuBar(point) else { return false }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NBIsEmptyMenuBarPoint(CGPoint(x: point.x, y: top - point.y))
    }

    private func togglePresentation(section: AppSections.Section = .hidden) {
        if arrangingIcons { arrangementWindow.show(); return }
        guard !isPending else { return }
        hoverSuppressed = true
        if preferences.enabled(.useBar) {
            if hiddenBar.isVisible && !hiddenBar.isSearching && presentedSection == section { rehidePresentation(); return }
            presentBar(searching: false, section: section)
        } else {
            if nativeItemsRevealed {
                if section == .hidden { rehidePresentation(); return }
                if presentedSection == .alwaysHidden { revealNativeSection(.hidden); return }
            }
            revealNativeSection(section)
        }
    }

    private func revealNativeSection(_ section: AppSections.Section) {
        guard !isPending else { return }
        guard !selected.isEmpty else { chooseApps(); return }
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard dismissTemporaryMenu() else { return }
        visibilityRequested = true
        restore(message: "Selected section is shown temporarily.", clearIntent: false)
        let generation = operation
        let remaining = section == .alwaysHidden ? Set<String>() : sections.alwaysHidden.intersection(currentBundles())
        isPending = true
        Task {
            let error = remaining.isEmpty ? nil : await activate(Array(remaining))
            guard generation == operation else { return }
            isPending = false
            if let error { restore(message: error); return }
            presentedSection = section
            nativeItemsRevealed = true
            presentationStarted = Date()
            pointerEnteredPresentation = pointerInMenuBar(NSEvent.mouseLocation)
            try? await Task.sleep(for: .seconds(1))
            if generation == operation { ensureControl() }
        }
    }

    private func dismissTemporaryMenu() -> Bool {
        guard let bundle = temporaryBundle else { return true }
        guard NBCancelMenu(bundle) else { setStatus("Close the open menu before opening another icon."); return false }
        menuWatch?.invalidate(); menuWatch = nil
        temporaryBundle = nil
        return true
    }

    private func rehidePresentation() {
        guard !arrangingIcons, !isPending, temporaryBundle == nil else { return }
        if nativeItemsRevealed && selected.contains(where: { NBMenuIsOpen($0) }) { return }
        presentationStarted = nil
        hiddenBar.close()
        if nativeItemsRevealed { hideSelectedApps() }
    }

    private func handleMenuBarEvent(_ event: NSEvent) {
        guard !arrangingIcons else { return }
        let point = NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            emptyClickWasVisible = hiddenBar.isVisible || nativeItemsRevealed
            if nativeItemsRevealed && preferences.enabled(.autoRehide) && preferences.rehide == .smart && !pointerInMenuBar(point) {
                rehidePresentation()
            }
            return
        }
        guard !isPending else { return }
        if event.type == .scrollWheel {
            guard preferences.enabled(.showOnScroll), pointerInMenuBar(point) else { return }
            let delta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2
            if delta > 5 && !hiddenBar.isVisible && !nativeItemsRevealed {
                requestedBarAnchor = pointerAnchor(point); togglePresentation()
            } else if delta < -5 { rehidePresentation() }
            return
        }
        guard isEmptyMenuPoint(point) else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.type == .rightMouseUp || (event.type == .leftMouseUp && modifiers == .control)), preferences.enabled(.secondaryMenu) {
            hiddenBar.close()
            settingsMenu?.popUp(positioning: nil, at: point, in: nil)
        } else if event.type == .leftMouseUp && modifiers.isEmpty && preferences.enabled(.showOnClick) {
            if emptyClickWasVisible { rehidePresentation() }
            else { requestedBarAnchor = pointerAnchor(point); togglePresentation() }
        }
    }

    private func checkHoverAndRehide() {
        guard !arrangingIcons, !isPending, temporaryBundle == nil else { return }
        let point = NSEvent.mouseLocation
        let inMenuBar = pointerInMenuBar(point)
        let inside = inMenuBar || hiddenBar.contains(point)
        if !inside { hoverSuppressed = false }
        if hiddenBar.isVisible || nativeItemsRevealed {
            if inside { pointerEnteredPresentation = true; pointerLeftPresentation = nil }
            else if pointerLeftPresentation == nil { pointerLeftPresentation = Date() }
            guard preferences.enabled(.autoRehide), !hiddenBar.isSearching, let started = presentationStarted else { return }
            let since = preferences.rehide == .smart ? (pointerLeftPresentation ?? Date()) : started
            if preferences.shouldRehide(elapsed: Date().timeIntervalSince(since), inside: inside,
                                        pointerEntered: pointerEnteredPresentation) { rehidePresentation() }
            return
        }
        guard preferences.enabled(.showOnHover), visibilityRequested, !hoverSuppressed,
              NSEvent.pressedMouseButtons == 0, inMenuBar, isEmptyMenuPoint(point) else { hoverStarted = nil; return }
        if hoverStarted == nil { hoverStarted = Date() }
        guard let started = hoverStarted, Date().timeIntervalSince(started) >= preferences.hoverDelay else { return }
        hoverStarted = nil
        requestedBarAnchor = pointerAnchor(point)
        togglePresentation()
    }

    private func resumeVisibility() {
        guard !arrangingIcons, visibilityRequested else { return }
        restore(message: "Refreshing menu bar visibility…", clearIntent: false)
        let generation = operation
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard operation == generation, visibilityRequested, AXIsProcessTrusted() else { return }
            hideSelectedApps()
        }
    }

    @objc private func statusClicked(_ sender: NSButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            hiddenBar.close()
            if let menu = settingsMenu, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: sender)
            }
        } else {
            let flags = NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]) ?? []
            togglePresentation(section: flags == .option ? .alwaysHidden : .hidden)
        }
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
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if temporaryBundle != nil, dismissTemporaryMenu() { hideSelectedApps() }
            else { rehidePresentation() }
        }
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
        presentBar(searching: false)
    }

    @objc private func toggleHiddenSection() { togglePresentation() }

    @objc private func showIconSearch() {
        if hiddenBar.isVisible && hiddenBar.isSearching { hiddenBar.close(); return }
        presentBar(searching: true)
    }

    @objc private func showAlwaysHidden() { togglePresentation(section: .alwaysHidden) }

    private func presentBar(searching: Bool, section: AppSections.Section = .hidden) {
        if arrangingIcons { arrangementWindow.show(); return }
        if temporaryBundle != nil {
            guard !isPending, dismissTemporaryMenu() else { return }
            hideSelectedApps(then: { [weak self] in self?.presentBar(searching: searching, section: section) })
            return
        }
        guard !isPending, let (anchor, screen) = presentationAnchor() else { return }
        requestedBarAnchor = nil
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard searching || !sections.bundles(in: section).isEmpty else {
            chooseApps()
            setStatus("Assign an app to the \(section.title) section first.")
            return
        }
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
        visibilityRequested = !selected.isEmpty
        if visibility.active && !cachedIcons.isEmpty && cachedScreenFrame == screen.frame && (!searching || cachedIncludesVisible) {
            let icons = searching ? cachedIcons : cachedIcons.filter { sections.bundles(in: section).contains($0.bundle) }
            guard !icons.isEmpty else {
                chooseApps()
                setStatus("No icons from the \(section.title) section are available on this display.")
                return
            }
            presentedSection = section
            presentationStarted = Date()
            pointerEnteredPresentation = pointerInMenuBar(NSEvent.mouseLocation)
            pointerLeftPresentation = nil
            hiddenBar.show(icons: icons, anchor: anchor, screen: screen, searching: searching, sectionTitle: section.title)
            return
        }
        // Restore for one fresh capture, then hide again before displaying the strip.
        restore(message: "Loading menu bar icons…", clearIntent: false)
        let generation = operation
        isPending = true
        let targets = selected.intersection(currentBundles())
        let captureTargets = searching ? Set(currentBundles().filter { !$0.hasPrefix("com.apple.") && $0 != Bundle.main.bundleIdentifier }) : targets
        Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let icons = try await HiddenBar.capture(bundles: captureTargets, screen: screen)
                guard generation == operation else { return }
                let error = targets.isEmpty ? nil : await activate(Array(targets))
                guard generation == operation else { return }
                isPending = false
                if let error { restore(message: error); return }
                cachedIcons = icons
                cachedScreenFrame = screen.frame
                cachedIncludesVisible = searching
                presentedSection = section
                let shown = searching ? icons : icons.filter { sections.bundles(in: section).contains($0.bundle) }
                guard !shown.isEmpty else { throw HiddenBar.BarError.noIcons }
                presentationStarted = Date()
                pointerEnteredPresentation = pointerInMenuBar(NSEvent.mouseLocation)
                pointerLeftPresentation = nil
                setStatus("Click NookBar to open hidden icons. Right-click for settings.")
                hiddenBar.show(icons: shown, anchor: anchor, screen: screen, searching: searching, sectionTitle: section.title)
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
        guard let entry = icon.entry, let (_, screen) = barAnchor() else { showAll(); return }
        operation += 1
        let generation = operation
        presentationStarted = nil
        temporaryBundle = icon.bundle
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
            guard error == nil, NBPressMenuBarEntry(entry, HiddenBar.captureFrame(for: screen)) else {
                restore(message: error ?? "This menu bar item changed or could not be opened. Apps have been restored; reopen the strip to refresh it.")
                return
            }
            let started = Date()
            menuWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, generation == self.operation else { return }
                    // Give a menu time to appear; keep the original item visible while it is open.
                    guard Date().timeIntervalSince(started) > 1, !NBMenuIsOpen(icon.bundle) else { return }
                    self.menuWatch?.invalidate(); self.menuWatch = nil
                    self.temporaryBundle = nil
                    self.hideSelectedApps()
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
        hideSelectedApps()
    }

    private func hideSelectedApps(then completion: (() -> Void)? = nil) {
        guard !arrangingIcons, !isPending else { return }
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let targets = selected.intersection(currentBundles()).filter { $0 != own && !$0.hasPrefix("com.apple.") }
        guard !targets.isEmpty else { showAll(); completion?(); return }
        visibilityRequested = true
        nativeItemsRevealed = false
        presentationStarted = nil
        temporaryBundle = nil
        menuWatch?.invalidate(); menuWatch = nil
        hiddenBar.close(notify: false)
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
            completion?()
            try? await Task.sleep(for: .seconds(1))
            if generation == operation { ensureControl() }
        }
    }

    @objc private func chooseApps() {
        showAll()
        refreshApps()
        if appWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "NookBar — Choose Apps"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 400)
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
            let intro = NSTextField(wrappingLabelWithString: "Choose a section for each app. Hidden opens with a click; Always Hidden opens with Option-click. Each app’s icons share a section across displays.")
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
            for (title, action) in [("Refresh Apps", #selector(refreshAppWindow)), ("Select All", #selector(selectAllApps)), ("Clear Selection", #selector(clearSelection)), ("Settings…", #selector(showPreferences))] {
                selectionButtons.addArrangedSubview(NSButton(title: title, target: self, action: action))
            }
            stack.addArrangedSubview(selectionButtons)
            let buttons = NSStackView()
            buttons.spacing = 8
            for (title, action) in [("Hide Selected", #selector(toggleVisibility)), ("Show All", #selector(showAll)), ("Hidden Icons", #selector(toggleHiddenSection)), ("Always-Hidden Icons", #selector(showAlwaysHidden))] {
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
            let row = NSStackView()
            row.spacing = 12
            let label = NSTextField(labelWithString: app.name)
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = app.bundle
            row.addArrangedSubview(label)
            let picker = NSPopUpButton()
            picker.identifier = .init(app.bundle)
            picker.target = self; picker.action = #selector(selectApp(_:))
            picker.setAccessibilityLabel("Section for \(app.name)")
            for section in AppSections.Section.allCases {
                picker.addItem(withTitle: section.title)
                picker.lastItem?.representedObject = section.rawValue
            }
            picker.selectItem(at: AppSections.Section.allCases.firstIndex(of: sections.section(for: app.bundle))!)
            picker.widthAnchor.constraint(equalToConstant: 150).isActive = true
            row.addArrangedSubview(picker)
            list.addArrangedSubview(row)
        }
        if apps.isEmpty { list.addArrangedSubview(NSTextField(labelWithString: "No apps found")) }
    }

    @objc private func selectApp(_ sender: NSPopUpButton) {
        guard let bundle = sender.identifier?.rawValue,
              let raw = sender.selectedItem?.representedObject as? String,
              let section = AppSections.Section(rawValue: raw) else { return }
        showAll()
        sections.assign(bundle, to: section)
        setStatus("\(sections.hidden.count) hidden, \(sections.alwaysHidden.count) always hidden. Click Hide Selected.")
    }

    @objc private func refreshAppWindow() {
        showAll()
        refreshApps()
        populateAppList()
        accessButton?.isHidden = AXIsProcessTrusted()
    }

    @objc private func selectAllApps() {
        showAll()
        sections.hideAll(Set(apps.map(\.bundle)))
        populateAppList()
        setStatus("\(selected.count) app(s) selected. Click Hide Selected.")
    }

    @objc private func clearSelection() {
        showAll()
        sections.clear()
        populateAppList()
        setStatus("Choose apps to tuck away.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appearance.stop()
        arrangementWindow.cancel()
        separatorLab?.stop()
        monitor?.invalidate()
        behaviorTimer?.invalidate()
        hotKeys.stop()
        if let emptyBarMonitor { NSEvent.removeMonitor(emptyBarMonitor) }
        if let localBarMonitor { NSEvent.removeMonitor(localBarMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
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
        let identityScreen = NSScreen.screens.first.map(HiddenBar.captureFrame(for:))
        let originalEntries = identityScreen.map { NBMenuBarEntries($0).filter { !$0.bundle.hasPrefix("com.apple.") } } ?? []
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
            if let frame = identityScreen, let entry = originalEntries.first(where: { $0.bundle == own }) {
                report["hiddenIdentityRejected"] = NBResolveMenuBarEntry(entry, frame) == nil
            }
            report["activationError"] = error ?? NSNull()
            visibility.restore()
            try? await Task.sleep(for: .seconds(2))
            let after = snapshot()
            report["after"] = after.counts
            if let frame = identityScreen {
                report["liveIdentitiesRestored"] = !originalEntries.isEmpty && originalEntries.allSatisfy {
                    NBResolveMenuBarEntry($0, frame) != nil
                }
            }
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
                let otherEntries = originalEntries.filter { $0.bundle == other }
                if let frame = identityScreen {
                    report["foreignHiddenIdentityRejected"] = !otherEntries.isEmpty && otherEntries.allSatisfy { NBResolveMenuBarEntry($0, frame) == nil }
                }
                visibility.restore()
                controlPanel?.orderOut(nil); controlPanel = nil
                try? await Task.sleep(for: .milliseconds(500))
                if let frame = identityScreen {
                    report["foreignIdentityRestored"] = !otherEntries.isEmpty && otherEntries.allSatisfy { NBResolveMenuBarEntry($0, frame) != nil }
                }
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
        if passed, let frame = identityScreen {
            let testItem = NSStatusBar.system.statusItem(withLength: 26)
            testItem.button?.title = "ID"
            testItem.button?.setAccessibilityLabel("NookBar identity test")
            try? await Task.sleep(for: .milliseconds(500))
            let stale = NBMenuBarEntries(frame).first { $0.bundle == own && $0.label == "NookBar identity test" }
            NSStatusBar.system.removeStatusItem(testItem)
            try? await Task.sleep(for: .milliseconds(500))
            let staleRejected = stale.map { NBResolveMenuBarEntry($0, frame) == nil } ?? false
            let livePreserved = originalEntries.first(where: { $0.bundle == own }).map { NBResolveMenuBarEntry($0, frame) != nil } ?? false
            report["removedIdentityRejected"] = staleRejected
            report["remainingIdentityPreserved"] = livePreserved
            let replacement = NSStatusBar.system.statusItem(withLength: 26)
            replacement.button?.title = "ID"
            replacement.button?.setAccessibilityLabel("NookBar identity test")
            try? await Task.sleep(for: .milliseconds(500))
            let fresh = NBMenuBarEntries(frame).first { $0.bundle == own && $0.label == "NookBar identity test" }
            let replacementRejected = stale.map { NBResolveMenuBarEntry($0, frame) == nil } ?? false
            let freshAccepted = fresh.map { NBResolveMenuBarEntry($0, frame) != nil } ?? false
            replacement.button?.setAccessibilityLabel("NookBar renamed identity test")
            try? await Task.sleep(for: .milliseconds(500))
            let renamedRejected = fresh.map { NBResolveMenuBarEntry($0, frame) == nil } ?? false
            NSStatusBar.system.removeStatusItem(replacement)
            report["sameLabelReplacementRejected"] = replacementRejected
            report["replacementIdentityAvailable"] = freshAccepted
            report["renamedIdentityRejected"] = renamedRejected
            // Record the same-label ABA case as a limitation of the macOS AX
            // interface, separately from supported hide/reveal and removal checks.
            report["identityIsolationProven"] = replacementRejected
            passed = passed && staleRejected && livePreserved && freshAccepted && renamedRejected
        }
        if let rejected = report["foreignHiddenIdentityRejected"] as? Bool { passed = passed && rejected }
        if let restored = report["foreignIdentityRestored"] as? Bool { passed = passed && restored }
        if let rejected = report["hiddenIdentityRejected"] as? Bool { passed = passed && rejected }
        if let restored = report["liveIdentitiesRestored"] as? Bool { passed = passed && restored }
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

if CommandLine.arguments.contains("--check-behavior") {
    BehaviorChecks.run()
} else if CommandLine.arguments.contains("--snapshot") {
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
