import AppKit
import ScreenCaptureKit
@preconcurrency import NativeMenuBar

@MainActor
final class HiddenBar: NSObject, NSWindowDelegate {
    struct Icon {
        let bundle: String
        let index: Int
        let label: String
        let image: NSImage
    }
    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    var onSelect: ((Icon) -> Void)?
    var onClose: (() -> Void)?
    var isControlWindow: ((NSWindow?) -> Bool)?
    var isVisible: Bool { panel?.isVisible == true }
    private var icons: [Icon] = []

    // AX and screenshot coordinates use a top-left origin; AppKit uses bottom-left.
    static func captureFrame(for screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    static func capture(bundles: Set<String>, screen: NSScreen) async throws -> [Icon] {
        let entries = NBMenuBarEntries(captureFrame(for: screen)).filter { bundles.contains($0.bundle) }
        guard !entries.isEmpty else { throw BarError.noIcons }
        // Only the icon rectangles' bounding strip is sampled. Images never leave memory.
        let rect = entries.reduce(CGRect.null) { $0.union($1.frame) }.integral
        let image = try await SCScreenshotManager.captureImage(in: rect)
        let sx = CGFloat(image.width) / rect.width, sy = CGFloat(image.height) / rect.height
        var indices: [String: Int] = [:]
        return try entries.map { entry in
            let index = indices[entry.bundle, default: 0]
            indices[entry.bundle] = index + 1
            let crop = CGRect(x: (entry.frame.minX - rect.minX) * sx,
                              y: (entry.frame.minY - rect.minY) * sy,
                              width: entry.frame.width * sx, height: entry.frame.height * sy).integral
            guard let cg = image.cropping(to: crop) else { throw BarError.noIcons }
            return Icon(bundle: entry.bundle, index: index, label: entry.label,
                        image: NSImage(cgImage: cg, size: entry.frame.size))
        }
    }

    func show(icons: [Icon], anchor: NSRect, screen: NSScreen) {
        close(notify: false)
        self.icons = icons
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for (index, icon) in icons.enumerated() {
            let button = NSButton(image: icon.image, target: self, action: #selector(selectIcon))
            button.tag = index
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.toolTip = icon.label
            button.setAccessibilityLabel(icon.label)
            button.widthAnchor.constraint(equalToConstant: max(28, icon.image.size.width + 8)).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            row.addArrangedSubview(button)
        }
        let width = row.fittingSize.width
        let visibleWidth = min(width, screen.frame.width - 32)
        let panel = IconPanel(contentRect: NSRect(x: 0, y: 0, width: visibleWidth, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NookBar — Hidden Icons"
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let scroll = NSScrollView(frame: effect.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = width > visibleWidth
        row.frame = NSRect(x: 0, y: 0, width: width, height: 44)
        scroll.documentView = row
        effect.addSubview(scroll)
        panel.contentView = effect
        let x = min(max(anchor.midX - visibleWidth / 2, screen.frame.minX + 8), screen.frame.maxX - visibleWidth - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 50))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel && self?.isControlWindow?(event.window) != true { self?.close() }
            }
            return event
        }
    }

    @objc private func selectIcon(_ sender: NSButton) {
        guard icons.indices.contains(sender.tag) else { return }
        let icon = icons[sender.tag]
        close(notify: false)
        onSelect?(icon)
    }

    func close(notify: Bool = true) {
        let wasVisible = isVisible
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil
        localMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        icons = []
        if notify && wasVisible { onClose?() }
    }

    enum BarError: LocalizedError {
        case noIcons
        var errorDescription: String? { "Could not capture the selected menu bar icons on this display. Show All, then try again." }
    }
}

@MainActor
private final class IconPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
