import AppKit
import ScreenCaptureKit
@preconcurrency import NativeMenuBar

// Developer-only UI for checking the original Ice divider mechanism on a new OS.
// It never rewrites an app's section assignment or moves another app's icons.
@MainActor
final class SeparatorLab: NSObject, NSWindowDelegate {
    private var items: [NSStatusItem] = []
    private var divider: NSStatusItem?
    private var window: NSWindow?
    private let report = NSTextField(wrappingLabelWithString: "")
    private let preview = NSImageView()
    private let previewCaption = NSTextField(labelWithString: "")
    private var captureGeneration = 0
    private var restorationTimer: Timer?
    private var before: [String: Int] = [:]
    private var moveTask: Task<Void, Never>?
    private var pendingMouseUp: CGEvent?
    private let names = ["NookBar.Lab.Right", "NookBar.Lab.Divider", "NookBar.Lab.Left"]

    func show() {
        for (position, name) in names.enumerated() {
            // Same AppKit preference used by Ice to initialize its dividers.
            UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position \(name)")
            let item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = name
            item.length = 24
            let title = position == 0 ? "R" : position == 1 ? "|" : "L"
            item.button?.title = title
            item.button?.setAccessibilityLabel("NookBar divider check \(title)")
            item.button?.toolTip = "NookBar divider check \(title)"
            items.append(item)
            if position == 1 { divider = item }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "NookBar — Divider Compatibility"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)
        ])
        let intro = NSTextField(wrappingLabelWithString: "This developer check adds L, |, and R to the menu bar. Expanding | tests Ice’s original hiding method. Items to its left may disappear temporarily; it contracts automatically after 10 seconds. Closing this window removes all three test items.")
        intro.widthAnchor.constraint(equalToConstant: 860).isActive = true
        stack.addArrangedSubview(intro)
        let buttons = NSStackView(); buttons.spacing = 10
        for (title, action) in [("Expand Divider", #selector(expand)), ("Expand With Wide Image", #selector(expandWithImage)), ("Contract Divider", #selector(contract)), ("Read Current State", #selector(readState)), ("Swap L and R", #selector(moveLeftItem))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        stack.addArrangedSubview(buttons)
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        report.widthAnchor.constraint(equalToConstant: 860).isActive = true
        stack.addArrangedSubview(report)
        preview.imageScaling = .scaleProportionallyDown
        preview.widthAnchor.constraint(equalToConstant: 860).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 60).isActive = true
        preview.setAccessibilityLabel("Current primary display menu bar")
        stack.addArrangedSubview(preview)
        previewCaption.textColor = .secondaryLabelColor
        stack.addArrangedSubview(previewCaption)
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        readState()
    }

    @objc private func expand() {
        captureGeneration += 1
        preview.image = nil; previewCaption.stringValue = ""
        before = NBMenuBarSnapshot()["occurrences"] as? [String: Int] ?? [:]
        restorationTimer?.invalidate()
        divider?.button?.title = ""
        divider?.button?.image = nil
        divider?.button?.appearsDisabled = true
        divider?.length = 10_000
        restorationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.contract() }
        }
        report.stringValue = "Divider requested width: 10,000. Read Current State to observe the result."
    }
    @objc private func expandWithImage() {
        // Test intrinsic image width separately from the legacy length setter.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10_000, pixelsHigh: 1,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 40_000, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData else { return }
        bytes.initialize(repeating: 0, count: 40_000)
        bitmap.size = NSSize(width: 10_000, height: 24)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        expand()
        divider?.button?.imageScaling = .scaleNone
        divider?.button?.image = image
        divider?.length = NSStatusItem.variableLength
        report.stringValue = "Divider now uses a transparent 10,000-point image and intrinsic width. It contracts after 10 seconds."
    }
    @objc private func contract() {
        captureGeneration += 1
        preview.image = nil; previewCaption.stringValue = ""
        restorationTimer?.invalidate(); restorationTimer = nil
        divider?.length = 24
        divider?.button?.image = nil
        divider?.button?.title = "|"
        divider?.button?.appearsDisabled = false
        report.stringValue = "Divider contracted. Read Current State to verify restoration."
    }
    // This is the native movement path under investigation, restricted to the
    // diagnostic's own L/R items. No foreign app identity is accepted here.
    @objc private func moveLeftItem() {
        guard moveTask == nil, divider?.length == 24,
              let screen = NSScreen.screens.first, CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right) else {
            report.stringValue = "Contract the divider and release mouse buttons before moving. Accessibility event access is required."
            return
        }
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen)).filter { $0.bundle == own }
        guard let left = entries.first(where: { $0.label == "NookBar divider check L" }),
              let right = entries.first(where: { $0.label == "NookBar divider check R" }),
              !left.frame.intersects(right.frame) else {
            report.stringValue = "L/R geometry is unavailable or overlaps. No movement was requested."
            return
        }
        let start = CGPoint(x: left.frame.midX, y: left.frame.midY)
        let targetX = left.frame.minX < right.frame.minX ? right.frame.maxX + 2 : right.frame.minX - 2
        let end = CGPoint(x: targetX, y: right.frame.midY)
        guard HiddenBar.captureFrame(for: screen).contains(end),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            report.stringValue = "Could not create a bounded move request."
            return
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        report.stringValue = "Requesting native Command-drag of our L item. Verify the captured menu bar afterward."
        moveTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { moveTask = nil }
            pendingMouseUp = up
            down.post(tap: .cghidEventTap)
            do {
                // Always release the mouse, including cancellation/window close.
                defer { releaseMoveMouse() }
                try await Task.sleep(for: .milliseconds(100))
                for step in 1...10 {
                    try Task.checkCancellation()
                    let fraction = CGFloat(step) / 10
                    let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                        y: start.y + (end.y - start.y) * fraction)
                    guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                             mouseCursorPosition: point, mouseButton: .left) else { break }
                    drag.flags = .maskCommand
                    drag.post(tap: .cghidEventTap)
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch { return }
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            readState()
        }
    }

    @objc private func readState() {
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let snapshot = NBMenuBarSnapshot()
        let counts = snapshot["occurrences"] as? [String: Int] ?? [:]
        var lines = ["Requested divider width: \(Int(divider?.length ?? 0))",
                     "Divider image width: \(Int(divider?.button?.image?.size.width ?? 0))",
                     "Own AX occurrences: \(counts[own] ?? 0)", "All AX groups: \(snapshot["groupCount"] ?? "unknown")"]
        if let screen = NSScreen.screens.first {
            for entry in NBMenuBarEntries(HiddenBar.captureFrame(for: screen)) where entry.bundle == own {
                lines.append("\(entry.label): x=\(Int(entry.frame.minX)), y=\(Int(entry.frame.minY)), width=\(Int(entry.frame.width))")
            }
            if let button = divider?.button, let window = button.window {
                lines.append("AppKit divider window: \(window.frame)")
            }
            if CGPreflightScreenCaptureAccess() {
                captureGeneration += 1
                let generation = captureGeneration
                let requested = Int(divider?.length ?? 0)
                let imageWidth = Int(divider?.button?.image?.size.width ?? 0)
                previewCaption.stringValue = "Capturing current menu bar…"
                let frame = HiddenBar.captureFrame(for: screen)
                let rect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 40)
                Task {
                    do {
                        // Let the status item's width animation settle before sampling.
                        try await Task.sleep(for: .milliseconds(750))
                        let image = try await SCScreenshotManager.captureImage(in: rect)
                        guard generation == captureGeneration else { return }
                        preview.image = NSImage(cgImage: image, size: rect.size)
                        previewCaption.stringValue = "Captured with divider requested width \(requested), image width \(imageWidth)."
                    } catch {
                        if generation == captureGeneration { previewCaption.stringValue = error.localizedDescription }
                    }
                }
            }
        }
        if !before.isEmpty {
            let missing = before.keys.filter { counts[$0] == nil && !$0.hasPrefix("com.apple.") && $0 != own }.sorted()
            lines.append("Apps absent since expansion: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
        }
        report.stringValue = lines.joined(separator: "\n")
    }
    private func releaseMoveMouse() {
        pendingMouseUp?.post(tap: .cghidEventTap)
        pendingMouseUp = nil
    }
    func windowWillClose(_ notification: Notification) { stop() }
    func stop() {
        moveTask?.cancel()
        releaseMoveMouse()
        captureGeneration += 1
        restorationTimer?.invalidate(); restorationTimer = nil
        for item in items {
            let name = item.autosaveName as String? ?? ""
            let key = "NSStatusItem Preferred Position \(name)"
            let position = UserDefaults.standard.object(forKey: key)
            NSStatusBar.system.removeStatusItem(item)
            UserDefaults.standard.set(position, forKey: key)
        }
        items = []; divider = nil
    }
}
