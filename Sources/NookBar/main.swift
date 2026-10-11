import AppKit
import ScreenCaptureKit
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
    private var iconRefreshTask: Task<Void, Never>?
    private var lastIconRefresh = Date.distantPast
    private var menuWatch: Timer?
    private var emptyBarMonitor: Any?
    private var requestedBarAnchor: (NSRect, NSScreen)?
    private var controlPanel: NSPanel?
    private var nativeControlAnchor: (NSRect, NSScreen)?
    private let preferences = Preferences()
    private lazy var spacing = MenuBarSpacing(defaults: preferences.defaults)
    private var relaunchingMenuApps = false
    private lazy var appearance = MenuBarAppearance(defaults: preferences.defaults)
    private lazy var preferencesWindow = PreferencesWindow(preferences: preferences, appearance: appearance, spacing: spacing)
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
    private var temporaryInterface: (entry: NBMenuBarEntry, windows: [NSNumber], window: NSNumber?)?
    private var temporaryRehideCheckAt: Double = 0
    private var interfaceProbePanel: NSPanel?
    private var pointerEnteredPresentation = false
    private var pointerLeftPresentation: Date?
    private var spacingProbeItems: [NSStatusItem] = []
    private var activatedProbe: Int?
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
        // Developer-only native spacing/overflow probes. No saved positions change.
        let overflowProbe = CommandLine.arguments.contains("--overflow-probe")
        if CommandLine.arguments.contains("--spacing-probe") || overflowProbe {
            for index in 1...(overflowProbe ? 24 : 3) {
                let probe = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                probe.button?.image = NSImage(systemSymbolName: "\(index).circle", accessibilityDescription: "NookBar spacing probe S\(index)")
                probe.button?.image?.isTemplate = true
                probe.button?.setAccessibilityLabel("NookBar spacing probe S\(index)")
                probe.button?.tag = index
                probe.button?.target = self
                probe.button?.action = #selector(probeClicked(_:))
                spacingProbeItems.append(probe)
            }
        }
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
        if CommandLine.arguments.contains("--overflow-check") {
            Task { await self.runOverflowCheck() }
            return
        }
        if CommandLine.arguments.contains("--refresh-check") {
            Task { await self.runRefreshCheck() }
            return
        }
        if CommandLine.arguments.contains("--interface-check") {
            Task { await self.runInterfaceCheck() }
            return
        }
        if CommandLine.arguments.contains("--width-check") {
            Task { await self.runWidthCheck() }
            return
        }
        if CommandLine.arguments.contains("--foreign-divider-check") {
            Task { await self.runForeignDividerCheck() }
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
        spacing.onBeginRelaunch = { [weak self] in
            guard let self, !isPending, !arrangingIcons, temporaryBundle == nil else { return false }
            relaunchingMenuApps = true
            self.restore(message: "Apps restored while menu bar apps relaunch.", clearIntent: false)
            return true
        }
        spacing.onEndRelaunch = { [weak self] in
            guard let self else { return }
            relaunchingMenuApps = false
            resumeVisibility()
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
                guard let self, !self.relaunchingMenuApps else { return }
                let bundles = self.currentBundles()
                if (self.visibility.active || self.isPending) && !AXIsProcessTrusted() {
                    self.restore(message: "Apps restored because Accessibility access was removed.")
                } else if bundles != self.runningBundles && self.visibilityRequested && !self.isPending && !self.arrangingIcons {
                    if self.temporaryBundle != nil && self.temporaryInterfaceIsOpen() {
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
            MainActor.assumeIsolated {
                self?.checkHoverAndRehide()
                self?.refreshDisplayedIcons()
            }
        }
        if selected.isEmpty || CommandLine.arguments.contains("--choose-apps") { chooseApps() }
        if ["--settings", "--appearance", "--spacing"].contains(where: CommandLine.arguments.contains),
           preferences.enabled(.hideOnLaunch), !selected.isEmpty {
            visibilityRequested = true
            resumeVisibility()
        }
        if CommandLine.arguments.contains("--settings") { showPreferences() }
        else if CommandLine.arguments.contains("--appearance") { showAppearance() }
        else if CommandLine.arguments.contains("--spacing") { openPreferences(tab: "Spacing") }
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
        iconRefreshTask?.cancel(); iconRefreshTask = nil
        HiddenBar.restoreOverflow()
        if clearIntent { visibilityRequested = false }
        nativeItemsRevealed = false
        presentationStarted = nil
        temporaryBundle = nil
        temporaryInterface = nil
        pointerLeftPresentation = nil
        operation += 1
        menuWatch?.invalidate()
        menuWatch = nil
        hiddenBar.close(notify: false)
        controlPanel?.orderOut(nil)
        controlPanel = nil
        visibility.restore()
        isPending = false
        setStatus(message)
    }

    @objc private func showAll() { restore(message: "All apps are shown.") }

    @objc private func showArrangement() {
        guard !relaunchingMenuApps else { return }
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
        guard !relaunchingMenuApps else { return }
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

    private func temporaryInterfaceIsOpen() -> Bool {
        if let temporaryInterface {
            return temporaryInterface.window.map { NBMenuBarInterfaceIsOpen(temporaryInterface.entry, $0) } ?? false
        }
        return temporaryBundle.map { NBMenuIsOpen($0) } ?? false
    }

    private func recordInteraction(_ stage: String, result: Bool? = nil) {
        guard let index = CommandLine.arguments.firstIndex(of: "--interaction-report"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let record: [String: Any] = ["stage": stage, "result": result.map { $0 as Any } ?? NSNull(),
            "bundle": temporaryBundle.map { $0 as Any } ?? NSNull(), "pending": isPending,
            "beforeWindows": temporaryInterface?.windows ?? [], "window": temporaryInterface?.window.map { $0 as Any } ?? NSNull(),
            "interfaceOpen": temporaryInterfaceIsOpen(), "visibilityActive": visibility.active]
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        do {
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .withoutOverwriting) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch { NSLog("NookBar interaction report failed: %@", error.localizedDescription) }
    }

    private func dismissTemporaryMenu() -> Bool {
        guard let bundle = temporaryBundle else { return true }
        if temporaryInterfaceIsOpen() && !NBMenuIsOpen(bundle) {
            setStatus("Close the item's open window or switch apps before opening another icon.")
            return false
        }
        guard NBCancelMenu(bundle) else { setStatus("Close the open menu before opening another icon."); return false }
        HiddenBar.restoreOverflow()
        menuWatch?.invalidate(); menuWatch = nil
        temporaryBundle = nil
        temporaryInterface = nil
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
        guard !arrangingIcons, !NBIsOwnMenuBarEvent(event.cgEvent) else { return }
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
                lastIconRefresh = Date()
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

    private func refreshDisplayedIcons() {
        guard hiddenBar.isVisible, let screen = hiddenBar.screen, !isPending, !arrangingIcons,
              !relaunchingMenuApps, temporaryBundle == nil, NSEvent.pressedMouseButtons == 0,
              Date().timeIntervalSince(lastIconRefresh) >= 3 else { return }
        lastIconRefresh = Date()
        let searching = hiddenBar.isSearching
        let section = presentedSection
        let targets = selected.intersection(currentBundles())
        let bundles = searching ? Set(currentBundles().filter { !$0.hasPrefix("com.apple.") && $0 != Bundle.main.bundleIdentifier }) : targets
        operation += 1
        let generation = operation
        isPending = true
        visibility.restore()
        iconRefreshTask = Task { [self] in
            defer { if generation == operation { iconRefreshTask = nil; isPending = false } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let icons = try await HiddenBar.capture(bundles: bundles, screen: screen)
                guard generation == operation, !Task.isCancelled else { return }
                if !targets.isEmpty, let error = await activate(Array(targets)) {
                    guard generation == operation else { return }
                    restore(message: error); return
                }
                guard generation == operation, !Task.isCancelled else { return }
                let shown = searching ? icons : icons.filter { sections.bundles(in: section).contains($0.bundle) }
                guard !shown.isEmpty else { throw HiddenBar.BarError.noIcons }
                if hiddenBar.isVisible { hiddenBar.update(icons: shown) }
            } catch {
                guard generation == operation else { return }
                restore(message: error.localizedDescription)
            }
        }
    }

    private func openHiddenIcon(_ icon: HiddenBar.Icon) {
        if iconRefreshTask != nil {
            iconRefreshTask?.cancel(); iconRefreshTask = nil
            HiddenBar.restoreOverflow()
            isPending = false
        }
        guard !isPending else { return }
        guard let entry = icon.entry, let (_, screen) = barAnchor() else { showAll(); return }
        operation += 1
        let generation = operation
        presentationStarted = nil
        temporaryBundle = icon.bundle
        temporaryInterface = nil
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
            if let error { restore(message: error); return }
            let opened = await HiddenBar.press(entry: entry, screen: screen) { current in
                guard generation == self.operation, let windows = NBMenuBarInterfaceWindowIDs(current) else { return false }
                // Snapshot after revealing/expanding the item, immediately
                // before its action, so exposure windows are not its interface.
                self.temporaryInterface = (current, windows, nil)
                self.recordInteraction("beforePress")
                return true
            }
            guard generation == operation else { return }
            recordInteraction("pressReturned", result: opened)
            guard opened else {
                restore(message: "This menu bar item changed or could not be opened. Apps have been restored; reopen the strip to refresh it.")
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == operation else { return }
            guard let context = temporaryInterface, let after = NBMenuBarInterfaceWindowIDs(context.entry) else {
                restore(message: "The item's window state could not be read. Apps have been restored.")
                return
            }
            let before = Set(context.windows)
            temporaryInterface = (context.entry, context.windows, after.first { !before.contains($0) })
            recordInteraction("interfaceCaptured")
            isPending = false
            temporaryRehideCheckAt = ProcessInfo.processInfo.systemUptime + preferences.tempShowInterval
            menuWatch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, generation == self.operation else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now >= self.temporaryRehideCheckAt else { return }
                    let buttonsReleased = (UInt32(0)...31).allSatisfy { value in
                        guard let button = CGMouseButton(rawValue: value) else { return true }
                        return !CGEventSource.buttonState(.combinedSessionState, button: button)
                    }
                    let paused = NSEvent.modifierFlags.isEmpty && buttonsReleased &&
                        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) > 0.25 &&
                        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel) > 0.25
                    if let delay = Preferences.temporaryRevealRetryDelay(interfaceOpen: self.temporaryInterfaceIsOpen(), inputPaused: paused) {
                        self.temporaryRehideCheckAt = now + delay
                        return
                    }
                    self.recordInteraction("interfaceClosed")
                    self.menuWatch?.invalidate(); self.menuWatch = nil
                    self.temporaryBundle = nil
                    self.temporaryInterface = nil
                    HiddenBar.restoreOverflow()
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
        guard !arrangingIcons, !isPending, !relaunchingMenuApps else { return }
        HiddenBar.restoreOverflow()
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let targets = selected.intersection(currentBundles()).filter { $0 != own && !$0.hasPrefix("com.apple.") }
        guard !targets.isEmpty else { showAll(); completion?(); return }
        visibilityRequested = true
        nativeItemsRevealed = false
        presentationStarted = nil
        temporaryBundle = nil
        temporaryInterface = nil
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
        guard !relaunchingMenuApps else { return }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if spacing.isBusy { preferencesWindow.report("Wait until menu bar apps finish relaunching before quitting NookBar."); return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconRefreshTask?.cancel()
        HiddenBar.restoreOverflow()
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

    @objc private func probeClicked(_ sender: NSButton) { activatedProbe = sender.tag }

    private func runOverflowCheck() async {
        // Test the native overflow control and our disposable icons only.
        try? await Task.sleep(for: .seconds(2))
        var report: [String: Any] = [:]
        if let screen = NSScreen.screens.first {
            let entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen)).filter {
                $0.bundle == Bundle.main.bundleIdentifier && $0.label.hasPrefix("NookBar spacing probe")
            }
            let exposed = entries.filter { NBMenuBarEntryIsExposed($0) }
            let collapsed = entries.filter { !NBMenuBarEntryIsExposed($0) }
            report["discovered"] = entries.map(\.label)
            report["exposed"] = exposed.map(\.label)
            report["collapsed"] = collapsed.map(\.label)
            var rejected = false
            do { _ = try await HiddenBar.capture(entries: entries) }
            catch HiddenBar.BarError.obscuredIcons { rejected = true }
            catch { report["captureError"] = error.localizedDescription }
            report["collapsedCaptureRejected"] = rejected
            do {
                let icons = try await HiddenBar.capture(entries: exposed)
                report["visibleCaptureCount"] = icons.count
                report["exposurePassed"] = entries.count == 24 && collapsed.count == 21 && rejected && exposed.count == 3 && icons.count == exposed.count
            } catch { report["visibleCaptureError"] = error.localizedDescription; report["passed"] = false }
            let frame = HiddenBar.captureFrame(for: screen)
            let initialOverflow = NBMenuBarOverflowState(frame)
            report["initialOverflow"] = initialOverflow
            if initialOverflow == 0 {
                report["expandRequested"] = NBSetMenuBarOverflowExpanded(frame, true)
                try? await Task.sleep(for: .milliseconds(500))
                if CommandLine.arguments.contains("--overflow-hold") {
                    try? await Task.sleep(for: .seconds(15))
                }
                let expanded = NBMenuBarEntries(frame).filter {
                    $0.bundle == Bundle.main.bundleIdentifier && $0.label.hasPrefix("NookBar spacing probe")
                }
                report["expandedOverflow"] = NBMenuBarOverflowState(frame)
                report["expandedCount"] = expanded.count
                report["expandedExposed"] = expanded.filter { NBMenuBarEntryIsExposed($0) }.map(\.label)
                do { report["expandedCaptureCount"] = try await HiddenBar.capture(entries: expanded).count }
                catch { report["expandedCaptureError"] = error.localizedDescription }
                do {
                    report["preexpandedCaptureCount"] = try await HiddenBar.capture(entries: expanded, screen: screen).count
                    report["preexpandedStatePreserved"] = NBMenuBarOverflowState(frame) == 1
                } catch { report["preexpandedCaptureError"] = error.localizedDescription }
                report["collapseRequested"] = NBSetMenuBarOverflowExpanded(frame, false)
                try? await Task.sleep(for: .milliseconds(500))
                report["restoredOverflow"] = NBMenuBarOverflowState(frame)
            }
            report["passed"] = (report["exposurePassed"] as? Bool == true) &&
                (report["expandedOverflow"] as? Int == 1) && (report["expandedCaptureCount"] as? Int == 24) &&
                (report["preexpandedCaptureCount"] as? Int == 24) && (report["preexpandedStatePreserved"] as? Bool == true) &&
                (report["restoredOverflow"] as? Int == 0)
            do {
                let icons = try await HiddenBar.capture(entries: entries, screen: screen)
                report["automaticCaptureCount"] = icons.count
                report["automaticRestoredOverflow"] = NBMenuBarOverflowState(frame)
                report["passed"] = (report["passed"] as? Bool == true) && icons.count == 24 && NBMenuBarOverflowState(frame) == 0
                if let entry = icons.first(where: { $0.label == "NookBar spacing probe S24" })?.entry {
                    report["activationRequested"] = await HiddenBar.press(entry: entry, screen: screen)
                    try? await Task.sleep(for: .milliseconds(300))
                    report["activationMatched"] = activatedProbe == 24
                    HiddenBar.restoreOverflow()
                    try? await Task.sleep(for: .milliseconds(500))
                    report["activationRestoredOverflow"] = NBMenuBarOverflowState(frame)
                    report["passed"] = (report["passed"] as? Bool == true) && activatedProbe == 24 && NBMenuBarOverflowState(frame) == 0
                } else { report["passed"] = false }
                if CommandLine.arguments.contains("--overflow-strip-preview"), let (anchor, _) = barAnchor() {
                    hiddenBar.show(icons: icons, anchor: anchor, screen: screen, sectionTitle: "Overflow probe")
                    try? await Task.sleep(for: .seconds(15))
                }
            } catch { report["automaticCaptureError"] = error.localizedDescription; report["passed"] = false }
        } else { report["passed"] = false }
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    // Only our disposable divider moves. No foreign position or saved section is written.
    private func runForeignDividerCheck() async {
        var report: [String: Any] = [:]
        func captureStage(_ name: String, frame: CGRect) async throws {
            guard let index = CommandLine.arguments.firstIndex(of: "--divider-capture-dir"), CommandLine.arguments.indices.contains(index + 1) else { return }
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try await SCScreenshotManager.captureImage(in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 40))
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try data?.write(to: folder.appendingPathComponent("\(name).png"))
        }
        let divider = NSStatusBar.system.statusItem(withLength: 24)
        divider.button?.title = "D"
        divider.button?.setAccessibilityLabel("NookBar foreign divider probe")
        let visibleControl = NSStatusBar.system.statusItem(withLength: 24)
        visibleControl.button?.title = "V"
        visibleControl.button?.setAccessibilityLabel("NookBar visible control probe")
        var removed = false
        defer { if !removed { NSStatusBar.system.removeStatusItem(divider); NSStatusBar.system.removeStatusItem(visibleControl) } }
        if let screen = NSScreen.screens.first {
            let frame = HiddenBar.captureFrame(for: screen)
            let initialOverflow = NBMenuBarOverflowState(frame)
            report["initialOverflow"] = initialOverflow
            var original: [NBMenuBarEntry] = []
            var systemObservations: [NBMenuBarEntry] = []
            do {
                try await Task.sleep(for: .seconds(2))
                let entries = NBMenuBarEntries(frame)
                let exposedForeign = entries.filter { NBMenuBarEntryIsExposed($0) && $0.bundle != Bundle.main.bundleIdentifier }
                original = exposedForeign.filter { NBSameMenuBarEntry($0, $0) }
                systemObservations = exposedForeign.filter { !NBSameMenuBarEntry($0, $0) }
                guard let source = entries.first(where: { $0.label == "NookBar foreign divider probe" }) else { throw MenuBarMovement.Failure.changed }
                let bundle = "eu.exelban.Stats"
                let pairs = zip(original, original.dropFirst()).filter { $0.bundle == bundle && $1.bundle == bundle }
                guard let pair = pairs.first else { throw MenuBarMovement.Failure.geometry }
                let left = pair.0, right = pair.1
                guard let controlEntry = entries.first(where: { $0.label == "NookBar visible control probe" }) else { throw MenuBarMovement.Failure.changed }
                try await MenuBarMovement().move(controlEntry, beside: right, before: false, screen: screen)
                report["bundle"] = bundle; report["leftLabel"] = left.label; report["rightLabel"] = right.label
                report["eventPostingAllowed"] = CGPreflightPostEventAccess()
                report["heldMouseButtons"] = [CGMouseButton.left, .right].filter { CGEventSource.buttonState(.combinedSessionState, button: $0) }.map { $0.rawValue }
                report["heldModifierKeys"] = [56, 58, 59, 60, 61, 62].filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
                try await MenuBarMovement().move(source, beside: right, before: true, screen: screen)
                let arranged = NBMenuBarEntries(frame)
                guard let liveRight = NBResolveMenuBarEntry(right, frame) else { throw MenuBarMovement.Failure.changed }
                let protected = arranged.filter { $0.bundle != Bundle.main.bundleIdentifier && $0.frame.minX >= liveRight.frame.minX && NBMenuBarEntryIsExposed($0) }
                try await captureStage("arranged", frame: frame)
                var stages: [[String: Any]] = []
                var chosenWidth: Int?
                for width in stride(from: 24, through: 600, by: 24) {
                    divider.length = CGFloat(width)
                    try await Task.sleep(for: .milliseconds(500))
                    let leftLive = NBResolveMenuBarEntry(left, frame), rightLive = NBResolveMenuBarEntry(right, frame)
                    let leftExposed = leftLive.map { NBMenuBarEntryIsExposed($0) } ?? false
                    let rightExposed = rightLive.map { NBMenuBarEntryIsExposed($0) } ?? false
                    let controlExposed = NBResolveMenuBarEntry(controlEntry, frame).map { NBMenuBarEntryIsExposed($0) } ?? false
                    let currentEntries = NBMenuBarEntries(frame)
                    let protectedFailures = protected.filter { entry in
                        if NBSameMenuBarEntry(entry, entry) {
                            return !(NBResolveMenuBarEntry(entry, frame).map { NBMenuBarEntryIsExposed($0) } ?? false)
                        }
                        // Read-only pixel-location observation for system extras without launch dates;
                        // this is not used to authorize movement, capture, or persistent membership.
                        let point = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
                        let matches = currentEntries.filter { $0.bundle == entry.bundle && $0.label == entry.label && NBMenuBarEntryMatchesPoint($0, point) && NBMenuBarEntryIsExposed($0) }
                        return matches.isEmpty
                    }
                    let protectedForeignExposed = !protectedFailures.contains { NBSameMenuBarEntry($0, $0) }
                    let protectedExposed = protectedFailures.isEmpty
                    let overflow = NBMenuBarOverflowState(frame)
                    stages.append(["width": width, "leftResolvable": leftLive != nil, "leftExposed": leftExposed,
                                   "rightExposed": rightExposed, "protectedRightExposed": protectedExposed,
                                   "visibleControlExposed": controlExposed,
                                   "protectedForeignRightExposed": protectedForeignExposed,
                                   "protectedFailures": protectedFailures.map(\.label), "overflow": overflow])
                    if leftLive != nil, !leftExposed, rightExposed, controlExposed, protectedForeignExposed, overflow == 0 {
                        report["visibleControlPreserved"] = true
                        chosenWidth = width; break
                    }
                    if !controlExposed || !protectedForeignExposed || (!leftExposed && overflow == -1) { break }
                }
                report["stages"] = stages
                report["independentForeignHideObserved"] = chosenWidth != nil
                if let chosenWidth {
                    report["chosenWidth"] = chosenWidth
                    try await captureStage("hidden", frame: frame)
                    report["hiddenForeignCaptureCount"] = try await HiddenBar.capture(entries: [left], screen: screen).count
                    report["captureRestoredCollapsed"] = NBMenuBarOverflowState(frame) == 0
                }
            } catch { report["error"] = error.localizedDescription }
            divider.length = 24
            HiddenBar.restoreOverflow()
            NSStatusBar.system.removeStatusItem(divider)
            NSStatusBar.system.removeStatusItem(visibleControl); removed = true
            try? await Task.sleep(for: .seconds(2))
            if initialOverflow == 0 && NBMenuBarOverflowState(frame) == 1 { _ = NBSetMenuBarOverflowExpanded(frame, false) }
            if initialOverflow == 1 && NBMenuBarOverflowState(frame) == 0 { _ = NBSetMenuBarOverflowExpanded(frame, true) }
            let restored = NBMenuBarEntries(frame)
            do { try await captureStage("restored", frame: frame) }
            catch { report["restorationCaptureError"] = error.localizedDescription }
            let positions = original.map { entry in restored.indices.filter { NBSameMenuBarEntry(restored[$0], entry) } }
            report["foreignOrderRestored"] = !original.isEmpty && positions.allSatisfy { $0.count == 1 }
                && zip(positions, positions.dropFirst()).allSatisfy { $0[0] < $1[0] }
            report["foreignExposureRestored"] = !original.isEmpty && original.allSatisfy { entry in
                let matches = restored.filter { NBSameMenuBarEntry($0, entry) }
                return matches.count == 1 && NBMenuBarEntryIsExposed(matches[0])
            }
            report["foreignDescriptorsResolvable"] = original.allSatisfy { NBResolveMenuBarEntry($0, frame) != nil }
            report["changedDescriptorLabels"] = original.filter { NBResolveMenuBarEntry($0, frame) == nil }.map(\.label)
            report["unexposedRestoredLabels"] = original.filter { entry in
                let matches = restored.filter { NBSameMenuBarEntry($0, entry) }
                return matches.count != 1 || !NBMenuBarEntryIsExposed(matches[0])
            }.map(\.label)
            report["systemRegionsRestored"] = systemObservations.allSatisfy { entry in
                let point = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
                return restored.contains { $0.bundle == entry.bundle && $0.label == entry.label && NBMenuBarEntryMatchesPoint($0, point) && NBMenuBarEntryIsExposed($0) }
            }
            report["systemObservationFrames"] = systemObservations.map { entry in
                ["label": entry.label, "beforeX": entry.frame.minX, "beforeWidth": entry.frame.width,
                 "after": restored.filter { $0.bundle == entry.bundle && $0.label == entry.label && NBMenuBarEntryIsExposed($0) }.map { ["x": $0.frame.minX, "width": $0.frame.width] }] as [String: Any]
            }
            report["finalOverflow"] = NBMenuBarOverflowState(frame)
            report["foreignPairCheckPassed"] = report["independentForeignHideObserved"] as? Bool == true
                && report["hiddenForeignCaptureCount"] as? Int == 1 && report["captureRestoredCollapsed"] as? Bool == true
                && report["foreignOrderRestored"] as? Bool == true && report["foreignExposureRestored"] as? Bool == true
                && NBMenuBarOverflowState(frame) == initialOverflow
            report["passed"] = report["foreignPairCheckPassed"] as? Bool == true && report["systemRegionsRestored"] as? Bool == true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private func runWidthCheck() async {
        var report: [String: Any] = [:]
        var probes: [NSStatusItem] = []
        for title in ["R", "D", "L"] {
            let item = NSStatusBar.system.statusItem(withLength: 24)
            item.button?.title = title
            item.button?.setAccessibilityLabel("NookBar width probe \(title)")
            item.button?.target = self; item.button?.action = #selector(probeClicked(_:))
            item.button?.tag = title == "L" ? 101 : title == "R" ? 102 : 103
            probes.append(item)
        }
        defer { for item in probes { NSStatusBar.system.removeStatusItem(item) } }
        if let screen = NSScreen.screens.first {
            let frame = HiddenBar.captureFrame(for: screen)
            try? await Task.sleep(for: .seconds(2))
            let initialOverflow = NBMenuBarOverflowState(frame)
            report["initialOverflow"] = initialOverflow
            var stages: [[String: Any]] = []
            for (stage, width) in [24, 100, 200, 400, 600, 800, 24].enumerated() {
                probes[1].length = CGFloat(width)
                try? await Task.sleep(for: .milliseconds(900))
                let entries = NBMenuBarEntries(frame).filter { $0.bundle == Bundle.main.bundleIdentifier && $0.label.hasPrefix("NookBar width probe") }
                stages.append(["requestedWidth": width, "appKitWidth": probes[1].button?.window?.frame.width ?? 0,
                    "overflow": NBMenuBarOverflowState(frame), "items": entries.map { entry in
                        ["label": entry.label, "x": entry.frame.minX, "y": entry.frame.minY, "width": entry.frame.width,
                         "exposed": NBMenuBarEntryIsExposed(entry)] as [String: Any]
                    }])
                if let index = CommandLine.arguments.firstIndex(of: "--width-capture-dir"), CommandLine.arguments.indices.contains(index + 1), CGPreflightScreenCaptureAccess() {
                    do {
                        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let image = try await SCScreenshotManager.captureImage(in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 40))
                        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                        try data?.write(to: folder.appendingPathComponent("stage\(stage)-\(width).png"))
                    } catch { report["captureError"] = error.localizedDescription }
                }
            }
            report["stages"] = stages
            probes[1].length = 200
            try? await Task.sleep(for: .seconds(1))
            let hiddenEntries = NBMenuBarEntries(frame).filter { $0.bundle == Bundle.main.bundleIdentifier && $0.label.hasPrefix("NookBar width probe") }
            if let left = hiddenEntries.first(where: { $0.label == "NookBar width probe L" }),
               let right = hiddenEntries.first(where: { $0.label == "NookBar width probe R" }) {
                report["independentHideObserved"] = !NBMenuBarEntryIsExposed(left) && NBMenuBarEntryIsExposed(right)
                do {
                    report["hiddenLeftCaptureCount"] = try await HiddenBar.capture(entries: [left], screen: screen).count
                    report["captureRestoredCollapsed"] = NBMenuBarOverflowState(frame) == 0
                    activatedProbe = nil
                    report["leftClickDelivered"] = await HiddenBar.press(entry: left, screen: screen)
                    try? await Task.sleep(for: .milliseconds(300))
                    report["leftActionObserved"] = activatedProbe == 101
                    HiddenBar.restoreOverflow()
                    try? await Task.sleep(for: .milliseconds(300))
                } catch { report["hiddenLeftError"] = error.localizedDescription }
            }
            probes[1].length = 24
            try? await Task.sleep(for: .seconds(1))
            let restored = NBMenuBarEntries(frame).filter { $0.bundle == Bundle.main.bundleIdentifier && $0.label.hasPrefix("NookBar width probe") }
            report["ownedItemsRestored"] = restored.count == 3 && restored.allSatisfy { NBMenuBarEntryIsExposed($0) }
            if initialOverflow == 0 && NBMenuBarOverflowState(frame) == 1 { _ = NBSetMenuBarOverflowExpanded(frame, false) }
            if initialOverflow == 1 && NBMenuBarOverflowState(frame) == 0 { _ = NBSetMenuBarOverflowExpanded(frame, true) }
            report["finalOverflow"] = NBMenuBarOverflowState(frame)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    @objc private func interfaceProbeClicked() {
        interfaceProbePanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runInterfaceCheck() async {
        var report: [String: Any] = [:]
        let originalFront = NSWorkspace.shared.frontmostApplication
        let existing = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 240, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        existing.title = "NookBar existing-window probe"
        existing.level = .normal; existing.hidesOnDeactivate = false
        let popup = NSPanel(contentRect: NSRect(x: 600, y: 300, width: 240, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        popup.title = "NookBar new-interface probe"
        popup.level = .normal; popup.hidesOnDeactivate = false
        interfaceProbePanel = popup
        let probe = NSStatusBar.system.statusItem(withLength: 28)
        probe.button?.image = NSImage(systemSymbolName: "29.circle", accessibilityDescription: "NookBar interface probe")
        probe.button?.image?.isTemplate = true
        probe.button?.setAccessibilityLabel("NookBar interface probe")
        probe.button?.target = self; probe.button?.action = #selector(interfaceProbeClicked)
        defer {
            restore(message: "Interface check finished.")
            existing.close(); popup.close(); interfaceProbePanel = nil
            NSStatusBar.system.removeStatusItem(probe)
            if NSApp.isActive { originalFront?.activate(options: []) }
        }
        existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do {
            try await Task.sleep(for: .seconds(2))
            guard let screen = NSScreen.screens.first,
                  let entry = NBMenuBarEntries(HiddenBar.captureFrame(for: screen)).first(where: { $0.label == "NookBar interface probe" }),
                  let windows = NBMenuBarInterfaceWindowIDs(entry) else { throw HiddenBar.BarError.noIcons }
            let existingWasVisible = windows.contains(NSNumber(value: existing.windowNumber))
            let icon = HiddenBar.Icon(bundle: entry.bundle, entry: entry, label: entry.label, appName: "NookBar", image: probe.button!.image!)
            openHiddenIcon(icon)
            try await Task.sleep(for: .seconds(3))
            report["legacyMenuDetection"] = NBMenuIsOpen(entry.bundle)
            report["appActive"] = NSApp.isActive
            report["actionObserved"] = popup.isVisible
            let held = popup.isVisible && temporaryBundle == entry.bundle && temporaryInterfaceIsOpen() && !isPending
            let excluded = existingWasVisible && temporaryInterface?.window != NSNumber(value: existing.windowNumber)
            report["existingWindowExcluded"] = excluded
            report["newNormalLayerInterfaceHeld"] = held
            popup.orderOut(nil)
            try await Task.sleep(for: .seconds(2))
            let minimumHeld = preferences.tempShowInterval <= 5 || (temporaryBundle == entry.bundle && !isPending)
            report["minimumDelayHeldAfterClosure"] = minimumHeld
            report["minimumDelay"] = preferences.tempShowInterval
            try await Task.sleep(for: .seconds(max(0, preferences.tempShowInterval - 5) + 4))
            let released = temporaryBundle == nil && temporaryInterface == nil && !isPending && (selected.isEmpty || visibility.active)
            report["closedInterfaceReleased"] = released
            report["passed"] = excluded && held && minimumHeld && released && !NBMenuIsOpen(entry.bundle)
        } catch { report["error"] = error.localizedDescription; report["passed"] = false }
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private func runRefreshCheck() async {
        var report: [String: Any] = [:]
        defer { restore(message: "Refresh check finished.") }
        do {
            guard let screen = NSScreen.screens.first, let button = statusItem?.button else { throw HiddenBar.BarError.noIcons }
            let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
            button.setAccessibilityLabel("NookBar refresh check")
            button.image = NSImage(systemSymbolName: "1.circle", accessibilityDescription: "NookBar refresh check")
            button.image?.isTemplate = true
            button.toolTip = "Tick 1"
            try await Task.sleep(for: .seconds(2))
            let entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen)).filter {
                $0.bundle == own && (spacingProbeItems.isEmpty || $0.label.hasPrefix("NookBar spacing probe S"))
            }
            report["discoveredCount"] = entries.count
            report["initialOverflow"] = NBMenuBarOverflowState(HiddenBar.captureFrame(for: screen))
            let icons = try await HiddenBar.capture(entries: entries, screen: screen)
            report["initialCaptureCount"] = icons.count
            guard let (anchor, _) = pointerAnchor(NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)) else { throw HiddenBar.BarError.noIcons }
            hiddenBar.show(icons: icons, anchor: anchor, screen: screen)
            func pixels(_ image: NSImage) -> Data? {
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                              bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let bytes = context.data else { return nil }
                // Render each crop independently; a cropped CGImage can retain
                // its composite screenshot's provider, which is not this icon.
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                return Data(bytes: bytes, count: cg.width * cg.height * 4)
            }
            var previous = icons
            let expectedCount = spacingProbeItems.isEmpty ? 1 : spacingProbeItems.count
            var refreshed = icons.count == expectedCount
            for tick in 2...3 {
                button.image = NSImage(systemSymbolName: "\(tick).circle", accessibilityDescription: "NookBar refresh check")
                button.image?.isTemplate = true
                button.toolTip = "Tick \(tick)"
                for probe in spacingProbeItems {
                    probe.button?.image = NSImage(systemSymbolName: "\(tick + 47).circle", accessibilityDescription: "NookBar spacing probe S\(probe.button?.tag ?? 0)")
                    probe.button?.image?.isTemplate = true
                }
                try await Task.sleep(for: .milliseconds(250))
                if CommandLine.arguments.contains("--refresh-hold") {
                    report["stage"] = "waitingBeforeTick\(tick)"
                    if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
                       let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
                    }
                    try await Task.sleep(for: .seconds(15))
                }
                let discovered = NBMenuBarEntries(HiddenBar.captureFrame(for: screen))
                let currentEntries = discovered.filter {
                    $0.bundle == own && (spacingProbeItems.isEmpty || $0.label.hasPrefix("NookBar spacing probe S"))
                }
                report["tick\(tick)DiscoveredCount"] = currentEntries.count
                report["tick\(tick)OverflowBeforeCapture"] = NBMenuBarOverflowState(HiddenBar.captureFrame(for: screen))
                hiddenBar.update(icons: try await HiddenBar.capture(entries: currentEntries, screen: screen))
                let current = hiddenBar.icons
                let changedCount = current.filter { icon in
                    guard let entry = icon.entry,
                          let old = previous.first(where: { $0.entry.map { NBSameMenuBarEntryDescriptor($0, entry) } ?? false }),
                          let newPixels = pixels(icon.image), let oldPixels = pixels(old.image) else { return false }
                    return newPixels != oldPixels
                }.count
                report["tick\(tick)PixelsChangedCount"] = changedCount
                report["tick\(tick)PanelVisible"] = hiddenBar.isVisible
                report["tick\(tick)IconCount"] = hiddenBar.icons.count
                report["tick\(tick)RestoredOverflow"] = NBMenuBarOverflowState(HiddenBar.captureFrame(for: screen))
                refreshed = refreshed && changedCount == expectedCount && current.count == expectedCount && hiddenBar.isVisible
                if !spacingProbeItems.isEmpty { refreshed = refreshed && NBMenuBarOverflowState(HiddenBar.captureFrame(for: screen)) == 0 }
                previous = current
            }
            report["passed"] = refreshed
        } catch { report["error"] = error.localizedDescription; report["passed"] = false }
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
        NSApp.terminate(nil)
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
            let unique = entries.enumerated().allSatisfy { index, entry in
                !entries.prefix(index).contains { NBSameMenuBarEntry($0, entry) && $0.frame == entry.frame }
            }
            let discovered = entries.filter { $0.bundle == own }.count == 1 && unique
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
                let current = NBMenuBarEntries(frame)
                report["liveIdentitiesRestored"] = !originalEntries.isEmpty && originalEntries.allSatisfy {
                    original in current.filter { NBSameMenuBarEntry($0, original) }.count == 1
                }
                report["liveEntriesResolvable"] = originalEntries.allSatisfy { NBResolveMenuBarEntry($0, frame) != nil }
                report["descriptionChangedBundles"] = originalEntries.filter { original in
                    current.contains { NBSameMenuBarEntry($0, original) && $0.label != original.label }
                }.map(\.bundle)
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
        if let resolved = report["liveEntriesResolvable"] as? Bool { passed = passed && resolved }
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
