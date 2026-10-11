import AppKit
import ScreenCaptureKit
@preconcurrency import NativeMenuBar

@MainActor
final class HiddenBar: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    struct Icon {
        let bundle: String
        let index: Int
        let label: String
        let appName: String
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
    private var searchStack: NSStackView?
    private var searchScroll: NSScrollView?
    private var searchField: NSSearchField?
    private var filteredIndices: [Int] = []
    private var searchSelection = 0
    private(set) var isSearching = false
    func contains(_ point: NSPoint) -> Bool { panel?.isVisible == true && panel?.frame.contains(point) == true }

    static func matchingIndices(in icons: [Icon], query: String) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return icons.indices.filter { index in
            let icon = icons[index]
            return query.isEmpty || [icon.label, icon.appName, icon.bundle].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    // AX and screenshot coordinates use a top-left origin; AppKit uses bottom-left.
    static func captureFrame(for screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    static func capture(bundles: Set<String>, screen: NSScreen) async throws -> [Icon] {
        let entries = NBMenuBarEntries(captureFrame(for: screen)).filter { bundles.contains($0.bundle) }
        return try await capture(entries: entries)
    }

    static func capture(entries: [NBMenuBarEntry]) async throws -> [Icon] {
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
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundle).first?.localizedName ?? entry.label
            return Icon(bundle: entry.bundle, index: index, label: entry.label, appName: appName,
                        image: NSImage(cgImage: cg, size: entry.frame.size))
        }
    }

    func show(icons: [Icon], anchor: NSRect, screen: NSScreen, searching: Bool = false, sectionTitle: String = "Hidden") {
        close(notify: false)
        self.icons = icons
        isSearching = searching
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for (index, icon) in icons.enumerated() {
            let button = NSButton(image: icon.image, target: self, action: #selector(selectIcon))
            button.tag = index
            button.isBordered = false
            button.imageScaling = .scaleNone
            button.toolTip = "\(icon.appName) — \(icon.label)"
            button.setAccessibilityLabel(icon.appName == icon.label ? icon.label : "\(icon.appName) — \(icon.label)")
            button.widthAnchor.constraint(equalToConstant: max(28, icon.image.size.width + 8)).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            row.addArrangedSubview(button)
        }
        let width = row.fittingSize.width
        let visibleWidth = min(searching ? 380 : width, screen.frame.width - 32)
        let height: CGFloat = searching ? min(340, screen.visibleFrame.height - 40) : 44
        let panel = IconPanel(contentRect: NSRect(x: 0, y: 0, width: visibleWidth, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = searching ? "NookBar — Search Icons" : "NookBar — \(sectionTitle) Icons"
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
        let scroll = NSScrollView(frame: searching ? NSRect(x: 8, y: 8, width: visibleWidth - 16, height: height - 52) : effect.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = !searching && width > visibleWidth
        if searching {
            let field = NSSearchField(frame: NSRect(x: 12, y: height - 36, width: visibleWidth - 24, height: 24))
            field.placeholderString = "Search menu bar icons"
            field.setAccessibilityLabel("Search menu bar icons")
            field.delegate = self
            effect.addSubview(field)
            searchField = field
            let list = SearchRows(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 2
            list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            scroll.hasVerticalScroller = true
            scroll.documentView = list
            searchStack = list; searchScroll = scroll; searchSelection = 0
            updateSearch()
        } else {
            row.frame = NSRect(x: 0, y: 0, width: width, height: 44)
            scroll.documentView = row
        }
        effect.addSubview(scroll)
        panel.contentView = effect
        let x = min(max(anchor.midX - visibleWidth / 2, screen.frame.minX + 8), screen.frame.maxX - visibleWidth - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 8, anchor.minY - height - 6)))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        if let searchField { panel.makeFirstResponder(searchField) }
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

    func controlTextDidChange(_ notification: Notification) {
        searchSelection = 0
        updateSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): searchSelection = min(searchSelection + 1, max(0, filteredIndices.count - 1)); updateSearch(); return true
        case #selector(NSResponder.moveUp(_:)): searchSelection = max(0, searchSelection - 1); updateSearch(); return true
        case #selector(NSResponder.insertNewline(_:)):
            guard filteredIndices.indices.contains(searchSelection) else { NSSound.beep(); return true }
            let icon = icons[filteredIndices[searchSelection]]
            close(notify: false); onSelect?(icon); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func updateSearch() {
        guard let list = searchStack, let scroll = searchScroll else { return }
        filteredIndices = Self.matchingIndices(in: icons, query: searchField?.stringValue ?? "")
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        let width = scroll.contentSize.width
        for (position, index) in filteredIndices.enumerated() {
            let icon = icons[index]
            let name = icon.appName == icon.label ? icon.appName : "\(icon.appName) — \(icon.label)"
            let button = NSButton(title: name, image: icon.image, target: self, action: #selector(selectIcon))
            button.tag = index
            button.bezelStyle = .recessed; button.setButtonType(.momentaryLight)
            button.isBordered = position == searchSelection
            button.imagePosition = .imageLeft; button.imageScaling = .scaleProportionallyDown
            button.alignment = .left
            button.state = position == searchSelection ? .on : .off
            button.toolTip = icon.bundle
            button.widthAnchor.constraint(equalToConstant: max(40, width - 8)).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            list.addArrangedSubview(button)
        }
        if filteredIndices.isEmpty {
            let empty = NSTextField(labelWithString: "No matching icons")
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: list.fittingSize.height)
        list.layoutSubtreeIfNeeded()
        if list.arrangedSubviews.indices.contains(searchSelection) {
            list.scrollToVisible(list.arrangedSubviews[searchSelection].frame)
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
        searchStack = nil; searchScroll = nil; searchField = nil
        filteredIndices = []; isSearching = false
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

@MainActor
private final class SearchRows: NSStackView {
    override var isFlipped: Bool { true }
}
