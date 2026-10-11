// SPDX-License-Identifier: GPL-3.0-or-later
// Shape/tint behavior follows Ice's MenuBarOverlayPanel and appearance configuration,
// copyright (C) 2024 Jordan Baird. See THIRD_PARTY_NOTICES.md.
import AppKit
import ScreenCaptureKit
@preconcurrency import NativeMenuBar

struct AppearanceColor: Codable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double = 1
    static let black = Self(red: 0, green: 0, blue: 0)
    static let white = Self(red: 1, green: 1, blue: 1)
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
    var normalized: Self {
        func bound(_ value: Double, fallback: Double = 0) -> Double { value.isFinite ? min(1, max(0, value)) : fallback }
        return Self(red: bound(red), green: bound(green), blue: bound(blue), alpha: bound(alpha, fallback: 1))
    }
}

struct AppearanceStop: Codable, Equatable, Identifiable {
    var id = UUID()
    var color: AppearanceColor
    var location: Double
}

struct AppearanceStyle: Codable, Equatable {
    enum Tint: String, Codable, CaseIterable { case none, solid, gradient }
    var shadow = false
    var border = false
    var borderColor = AppearanceColor.black
    var borderWidth = 1.0
    var tint = Tint.none
    var tintColor = AppearanceColor.black
    var stops = [AppearanceStop(color: .white, location: 0), AppearanceStop(color: .black, location: 1)]
    var hasEffect: Bool { shadow || border || tint != .none }
    var normalized: Self {
        var value = self
        value.borderColor = borderColor.normalized; value.tintColor = tintColor.normalized
        value.borderWidth = borderWidth.isFinite ? min(3, max(1, borderWidth)) : 1
        value.stops = stops.map {
            AppearanceStop(id: $0.id, color: $0.color.normalized, location: $0.location.isFinite ? min(1, max(0, $0.location)) : 0)
        }.sorted { $0.location < $1.location }
        if value.stops.count < 2 { value.stops = Self().stops }
        // Duplicate IDs cannot be addressed independently by the gradient editor.
        var seen = Set<UUID>()
        for index in value.stops.indices where !seen.insert(value.stops[index].id).inserted { value.stops[index].id = UUID() }
        return value
    }
}

struct AppearanceConfiguration: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable { case none, full, split }
    enum Cap: String, Codable, CaseIterable { case square, round }
    struct Ends: Codable, Equatable { var left = Cap.round; var right = Cap.round }
    var dynamic = false
    var standard = AppearanceStyle()
    var light = AppearanceStyle()
    var dark = AppearanceStyle()
    var shape = Shape.none
    var full = Ends()
    var menus = Ends()
    var icons = Ends()
    var inset = true
    var normalized: Self {
        var value = self
        value.standard = standard.normalized; value.light = light.normalized; value.dark = dark.normalized
        return value
    }
    func style(dark: Bool) -> AppearanceStyle { dynamic ? (dark ? self.dark : light) : standard }
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "MenuBarAppearance"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized
    }
    func save(to defaults: UserDefaults) { defaults.set(try? JSONEncoder().encode(normalized), forKey: "MenuBarAppearance") }

    struct Piece { let rect: CGRect; let ends: Ends }
    func pieces(in bounds: CGRect, menuWidth: CGFloat?, iconStart: CGFloat?, hasNotch: Bool) -> [Piece] {
        guard bounds.width > 0, bounds.height > 0, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite) else { return [] }
        if shape == .none { return [Piece(rect: bounds, ends: Ends(left: .square, right: .square))] }
        let amount: CGFloat = hasNotch ? (inset ? 3.5 : 0) : 1
        var rect = bounds.insetBy(dx: 0, dy: amount)
        let outside = shape == .full ? full : Ends(left: menus.left, right: icons.right)
        if outside.left == .round { rect.origin.x += amount; rect.size.width -= amount }
        if outside.right == .round { rect.size.width -= amount }
        guard rect.width > 0, rect.height > 0 else { return [] }
        guard shape == .split, let menuWidth, let iconStart, menuWidth.isFinite, iconStart.isFinite else { return [Piece(rect: rect, ends: outside)] }
        let leftEnd = min(rect.maxX, max(rect.minX, menuWidth + (hasNotch && inset ? 10 : 20)))
        let rightStart = max(rect.minX, min(rect.maxX, iconStart - 7))
        guard leftEnd > rect.minX, rightStart < rect.maxX, leftEnd < rightStart else { return [Piece(rect: rect, ends: outside)] }
        return [Piece(rect: CGRect(x: rect.minX, y: rect.minY, width: leftEnd - rect.minX, height: rect.height), ends: menus),
                Piece(rect: CGRect(x: rightStart, y: rect.minY, width: rect.maxX - rightStart, height: rect.height), ends: icons)]
    }
    static func path(for pieces: [Piece]) -> NSBezierPath {
        let result = NSBezierPath()
        for piece in pieces {
            let r = piece.rect, radius = min(r.height / 2, r.width / 2)
            let left = piece.ends.left == .round ? radius : 0
            let right = piece.ends.right == .round ? radius : 0
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX + left, y: r.minY))
            path.line(to: NSPoint(x: r.maxX - right, y: r.minY))
            if right > 0 { path.appendArc(withCenter: NSPoint(x: r.maxX - right, y: r.midY), radius: right, startAngle: 270, endAngle: 90) }
            else { path.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
            path.line(to: NSPoint(x: r.minX + left, y: r.maxY))
            if left > 0 { path.appendArc(withCenter: NSPoint(x: r.minX + left, y: r.midY), radius: left, startAngle: 90, endAngle: 270) }
            else { path.line(to: NSPoint(x: r.minX, y: r.minY)) }
            path.close(); result.append(path)
        }
        return result
    }
}

@MainActor
final class MenuBarAppearance: ObservableObject {
    @Published var configuration: AppearanceConfiguration {
        didSet { configuration.save(to: defaults); scheduleUpdate() }
    }
    @Published private(set) var status = "Appearance follows macOS."
    enum Preview { case light, dark }
    var preview: Preview? { didSet { scheduleUpdate() } }
    private let defaults: UserDefaults
    private var panels: [CGDirectDisplayID: AppearancePanel] = [:]
    private var captureTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var updateTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var themeObservation: NSKeyValueObservation?
    private var lastCapture: [CGDirectDisplayID: Date] = [:]
    private var suspended = false
    private var generation = 0
    init(defaults: UserDefaults) { self.defaults = defaults; configuration = .load(from: defaults) }
    var current: AppearanceStyle {
        if let preview { return preview == .dark ? configuration.dark : configuration.light }
        return configuration.style(dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    var autoHidden: Bool { UserDefaults.standard.bool(forKey: "_HIHideMenuBar") }
    func start() {
        guard observers.isEmpty else { return }
        themeObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.invalidateWallpaper() }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.invalidateWallpaper() }
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")) { $0.invalidateWallpaper() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { $0.invalidateWallpaper() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { $0.scheduleUpdate() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { $0.suspended = true; $0.preview = nil; $0.removePanels() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { $0.suspended = false; $0.invalidateWallpaper() }
        }
        scheduleUpdate()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor (MenuBarAppearance) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
    private func invalidateWallpaper() { removePanels(); scheduleUpdate() }
    private func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            update()
        }
    }
    private func removePanels() {
        generation += 1
        for task in captureTasks.values { task.cancel() }
        captureTasks = [:]; lastCapture = [:]
        for panel in panels.values { panel.close() }
        panels = [:]
    }
    func stop() {
        updateTask?.cancel(); timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []; removePanels()
        themeObservation = nil
    }
    private static func visibleBar(on screen: CGRect) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let data = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: data), rect.height >= 14, rect.height <= 80,
                  abs(rect.minY - screen.minY) < 2, rect.width >= screen.width * 0.8,
                  screen.contains(rect) else { continue }
            return rect
        }
        return nil
    }
    private func update() {
        let config = configuration.normalized, style = current.normalized
        guard !suspended, !autoHidden, AXIsProcessTrusted(), config.shape != .none || style.hasEffect else {
            timer?.invalidate(); timer = nil; removePanels()
            if autoHidden { status = "Appearance is paused while the menu bar hides automatically." }
            else if !AXIsProcessTrusted() { status = "Enable Accessibility access to apply menu bar appearance." }
            else { status = "Appearance follows macOS." }
            return
        }
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } } }
        var live = Set<CGDirectDisplayID>()
        var shown = 0
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value, screenFrame = HiddenBar.captureFrame(for: screen)
            live.insert(id)
            guard let bar = Self.visibleBar(on: screenFrame) else { panels[id]?.orderOut(nil); continue }
            let panel = panels[id] ?? AppearancePanel()
            panels[id] = panel
            let target = CGRect(x: bar.minX, y: screen.frame.maxY - bar.height - 5, width: bar.width, height: bar.height + 5)
            if panel.frame != target { panel.setFrame(target, display: false); panel.wallpaper = nil; lastCapture[id] = nil }
            let menu = NBApplicationMenuFrame(screenFrame)
            let entries = NBMenuBarEntries(screenFrame)
            let menuWidth = menu.isNull ? nil : Optional(menu.maxX - bar.minX)
            let iconStart = entries.map(\.frame.minX).min().map { $0 - bar.minX }
            panel.configuration = config; panel.style = style
            panel.pieces = config.pieces(in: CGRect(x: 0, y: 5, width: bar.width, height: bar.height), menuWidth: menuWidth, iconStart: iconStart, hasNotch: screen.safeAreaInsets.top > 0)
            if config.shape != .none && !CGPreflightScreenCaptureAccess() {
                panel.orderOut(nil); panel.wallpaper = nil
                status = "Enable Screen Recording to use Full or Split shapes."; continue
            }
            if config.shape == .none || panel.wallpaper != nil { panel.orderFrontRegardless(); shown += 1 }
            panel.contentView?.needsDisplay = true
            if config.shape != .none, captureTasks[id] == nil, Date().timeIntervalSince(lastCapture[id] ?? .distantPast) > 5 {
                captureWallpaper(id: id, screen: screenFrame, bar: bar, scale: screen.backingScaleFactor, panel: panel)
            }
        }
        for id in Set(panels.keys).subtracting(live) { panels.removeValue(forKey: id)?.close(); captureTasks.removeValue(forKey: id)?.cancel(); lastCapture[id] = nil }
        if shown > 0 { status = preview == nil ? "Appearance applied. Changes are saved automatically." : "Previewing \(preview == .dark ? "dark" : "light") appearance." }
    }
    private func captureWallpaper(id: CGDirectDisplayID, screen: CGRect, bar: CGRect, scale: CGFloat, panel: AppearancePanel) {
        let request = generation
        lastCapture[id] = Date()
        captureTasks[id] = Task { [weak self, weak panel] in
            guard let self, let panel else { return }
            defer { if request == generation { captureTasks[id] = nil } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let wallpaper = content.windows.first(where: { $0.owningApplication?.bundleIdentifier == "com.apple.wallpaper.agent" && $0.frame.contains(screen) }) else {
                    throw AppearanceError.wallpaper
                }
                let filter = SCContentFilter(desktopIndependentWindow: wallpaper)
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: bar.minX - wallpaper.frame.minX, y: bar.minY - wallpaper.frame.minY, width: bar.width, height: bar.height)
                config.width = Int(bar.width * scale); config.height = Int(bar.height * scale)
                config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard !Task.isCancelled, request == generation, panels[id] === panel,
                      configuration.shape != .none, CGPreflightScreenCaptureAccess(), Self.visibleBar(on: screen) == bar else { return }
                panel.wallpaper = NSImage(cgImage: image, size: bar.size)
                panel.contentView?.needsDisplay = true
                panel.orderFrontRegardless()
                status = preview == nil ? "Appearance applied. Changes are saved automatically." : "Previewing \(preview == .dark ? "dark" : "light") appearance."
            } catch {
                guard !Task.isCancelled, request == generation else { return }
                panel.orderOut(nil); panel.wallpaper = nil
                status = "Could not load the wallpaper strip. The original menu bar is shown. \(error.localizedDescription)"
            }
        }
    }
    private enum AppearanceError: LocalizedError {
        case wallpaper
        var errorDescription: String? { "No wallpaper source was available for this display." }
    }
}

@MainActor
private final class AppearancePanel: NSPanel {
    var configuration = AppearanceConfiguration()
    var style = AppearanceStyle()
    var pieces: [AppearanceConfiguration.Piece] = []
    var wallpaper: NSImage?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "NookBar Menu Bar Appearance"
        level = .statusBar; backgroundColor = .clear; isOpaque = false; hasShadow = false
        hidesOnDeactivate = false; ignoresMouseEvents = true; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .ignoresCycle]
        let view = AppearanceDrawing(); view.panel = self; contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
}

@MainActor
private final class AppearanceDrawing: NSView {
    weak var panel: AppearancePanel?
    override func draw(_ dirtyRect: NSRect) {
        guard let panel else { return }
        let rect = CGRect(x: 0, y: 5, width: bounds.width, height: bounds.height - 5)
        let path = AppearanceConfiguration.path(for: panel.pieces), style = panel.style
        func outsideClip() { let inverse = NSBezierPath(rect: bounds); inverse.append(path); inverse.windingRule = .evenOdd; inverse.setClip() }
        if panel.configuration.shape != .none {
            NSGraphicsContext.saveGraphicsState()
            outsideClip(); panel.wallpaper?.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            if style.shadow {
                NSGraphicsContext.saveGraphicsState(); outsideClip()
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
                shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
                NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            }
        } else if style.shadow {
            NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.2)])?.draw(in: CGRect(x: 0, y: 0, width: bounds.width, height: 5), angle: 90)
        }
        NSGraphicsContext.saveGraphicsState(); path.setClip()
        switch style.tint {
        case .none: break
        case .solid: style.tintColor.color.withAlphaComponent(0.2).setFill(); rect.fill()
        case .gradient:
            var locations = style.stops.map { CGFloat($0.location) }
            NSGradient(colors: style.stops.map { $0.color.color.withAlphaComponent(0.2) }, atLocations: &locations, colorSpace: .sRGB)?.draw(in: rect, angle: 0)
        }
        if style.border {
            style.borderColor.color.setStroke()
            if panel.configuration.shape == .none {
                style.borderColor.color.setFill(); CGRect(x: 0, y: 5, width: rect.width, height: style.borderWidth).fill()
            } else { path.lineWidth = style.borderWidth * 2; path.stroke() }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func isAccessibilityElement() -> Bool { false }
}
