import AppKit
import ScreenCaptureKit
@preconcurrency import NativeMenuBar

@MainActor
final class HiddenBar: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    struct Icon {
        let bundle: String
        let entry: NBMenuBarEntry?
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
    private(set) var icons: [Icon] = []
    private var searchStack: NSStackView?
    private var searchScroll: NSScrollView?
    private var searchField: NSSearchField?
    private var iconScroll: NSScrollView?
    private var presentationAnchor: NSRect?
    private(set) var screen: NSScreen?
    private var filteredIndices: [Int] = []
    private var searchSelection = 0
    private(set) var isSearching = false
    private static var overflowLease: (id: UUID, frame: CGRect)?
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
        return try await capture(entries: entries, screen: screen)
    }

    static func restoreOverflow() {
        guard let lease = overflowLease else { return }
        _ = NBSetMenuBarOverflowExpanded(lease.frame, false)
        overflowLease = nil
    }

    static func press(entry: NBMenuBarEntry, screen: NSScreen) async -> Bool {
        let frame = captureFrame(for: screen)
        guard let current = NBResolveMenuBarEntry(entry, frame) else { return false }
        if NBMenuBarEntryIsExposed(current) { return NBPressMenuBarEntry(entry, frame) }
        guard overflowLease == nil, NBMenuBarOverflowState(frame) == 0 else { return false }
        let id = UUID()
        overflowLease = (id, frame)
        var opened = false
        defer { if !opened && overflowLease?.id == id { restoreOverflow() } }
        guard NBSetMenuBarOverflowExpanded(frame, true) else { return false }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            guard overflowLease?.id == id else { return false }
            if let resolved = NBResolveMenuBarEntry(entry, frame), NBMenuBarEntryIsExposed(resolved) {
                opened = NBPressMenuBarEntry(entry, frame)
                return opened // Keep the overflow open while the item's menu is in use.
            }
        } while Date() < deadline
        return false
    }

    static func capture(entries: [NBMenuBarEntry], screen: NSScreen) async throws -> [Icon] {
        if entries.allSatisfy({ NBMenuBarEntryIsExposed($0) }) { return try await capture(entries: entries) }
        let frame = captureFrame(for: screen)
        guard overflowLease == nil, NBMenuBarOverflowState(frame) == 0 else { throw BarError.obscuredIcons }
        let id = UUID()
        overflowLease = (id, frame)
        defer { if overflowLease?.id == id { restoreOverflow() } }
        guard NBSetMenuBarOverflowExpanded(frame, true) else { throw BarError.obscuredIcons }
        let deadline = Date().addingTimeInterval(2)
        var ready: [NBMenuBarEntry]?
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            guard overflowLease?.id == id else { throw BarError.changedIcons }
            let current = NBMenuBarEntries(frame).filter { candidate in entries.contains { NBSameMenuBarEntry($0, candidate) } }
            if current.count == entries.count && entries.allSatisfy({ original in
                let matches = current.filter { NBSameMenuBarEntryDescriptor($0, original) }
                return matches.count == 1 && NBMenuBarEntryIsExposed(matches[0])
            }) { ready = current; break }
        } while Date() < deadline
        guard let ready else { throw BarError.obscuredIcons }
        let icons = try await capture(entries: ready)
        guard overflowLease?.id == id, NBSetMenuBarOverflowExpanded(frame, false) else { throw BarError.overflowRestore }
        let restoreDeadline = Date().addingTimeInterval(2)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            guard overflowLease?.id == id else { throw BarError.changedIcons }
            if NBMenuBarOverflowState(frame) == 0 { overflowLease = nil; return icons }
        } while Date() < restoreDeadline
        throw BarError.overflowRestore
    }

    static func capture(entries: [NBMenuBarEntry]) async throws -> [Icon] {
        guard !entries.isEmpty else { throw BarError.noIcons }
        guard entries.allSatisfy({ NBMenuBarEntryIsExposed($0) }) else { throw BarError.obscuredIcons }
        // Only the icon rectangles' bounding strip is sampled. Images never leave memory.
        let rect = entries.reduce(CGRect.null) { $0.union($1.frame) }.integral
        let image = try await SCScreenshotManager.captureImage(in: rect)
        let current = NBMenuBarEntries(rect)
        guard entries.allSatisfy({ entry in
            let matches = current.filter { NBSameMenuBarEntryDescriptor($0, entry) }
            return matches.count == 1 && matches[0].frame == entry.frame && NBMenuBarEntryIsExposed(matches[0])
        }) else { throw BarError.changedIcons }
        let sx = CGFloat(image.width) / rect.width, sy = CGFloat(image.height) / rect.height
        return try entries.map { original in
            guard let entry = current.first(where: { NBSameMenuBarEntryDescriptor($0, original) }) else { throw BarError.changedIcons }
            let crop = CGRect(x: (entry.frame.minX - rect.minX) * sx,
                              y: (entry.frame.minY - rect.minY) * sy,
                              width: entry.frame.width * sx, height: entry.frame.height * sy).integral
            guard let cg = image.cropping(to: crop) else { throw BarError.noIcons }
            let appName = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundle).first?.localizedName ?? entry.label
            return Icon(bundle: entry.bundle, entry: entry, label: entry.label, appName: appName,
                        image: NSImage(cgImage: cg, size: entry.frame.size))
        }
    }

    private func makeIconRow() -> NSStackView {
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
        return row
    }

    func update(icons: [Icon]) {
        guard let panel, let screen, let anchor = presentationAnchor else { return }
        let selected = filteredIndices.indices.contains(searchSelection) ? self.icons[filteredIndices[searchSelection]].entry : nil
        self.icons = icons
        if isSearching {
            let origin = searchScroll?.contentView.bounds.origin ?? .zero
            let matches = Self.matchingIndices(in: icons, query: searchField?.stringValue ?? "")
            if let selected, let position = matches.firstIndex(where: { index in
                icons[index].entry.map { NBSameMenuBarEntryDescriptor($0, selected) } ?? false
            }) { searchSelection = position }
            else { searchSelection = min(searchSelection, max(0, matches.count - 1)) }
            updateSearch(scrollToSelection: false)
            searchScroll?.contentView.scroll(to: origin)
            if let searchScroll { searchScroll.reflectScrolledClipView(searchScroll.contentView) }
        } else if let scroll = iconScroll {
            let origin = scroll.contentView.bounds.origin
            let row = makeIconRow()
            let width = row.fittingSize.width
            let visibleWidth = min(width, screen.frame.width - 32)
            row.frame = NSRect(x: 0, y: 0, width: width, height: 44)
            scroll.documentView = row
            scroll.hasHorizontalScroller = width > visibleWidth
            let x = min(max(anchor.midX - visibleWidth / 2, screen.frame.minX + 8), screen.frame.maxX - visibleWidth - 8)
            panel.setFrame(NSRect(x: x, y: panel.frame.minY, width: visibleWidth, height: panel.frame.height), display: true)
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func show(icons: [Icon], anchor: NSRect, screen: NSScreen, searching: Bool = false, sectionTitle: String = "Hidden") {
        close(notify: false)
        self.icons = icons
        self.screen = screen
        presentationAnchor = anchor
        isSearching = searching
        let row = makeIconRow()
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
            iconScroll = scroll
        }
        effect.addSubview(scroll)
        panel.contentView = effect
        let x = min(max(anchor.midX - visibleWidth / 2, screen.frame.minX + 8), screen.frame.maxX - visibleWidth - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 8, anchor.minY - height - 6)))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        if let searchField { panel.makeFirstResponder(searchField) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard !NBIsOwnMenuBarOverflowEvent(event.cgEvent) else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if NBIsOwnMenuBarOverflowEvent(event.cgEvent) { return event }
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

    private func updateSearch(scrollToSelection: Bool = true) {
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
        if scrollToSelection && list.arrangedSubviews.indices.contains(searchSelection) {
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
        iconScroll = nil; screen = nil; presentationAnchor = nil
        filteredIndices = []; isSearching = false
        if notify && wasVisible { onClose?() }
    }

    enum BarError: LocalizedError {
        case noIcons, changedIcons, obscuredIcons, overflowRestore
        var errorDescription: String? {
            switch self {
            case .noIcons: "Could not capture the selected menu bar icons on this display. Show All, then try again."
            case .changedIcons: "The menu bar changed while its icons were being captured. Refresh or reopen the strip."
            case .obscuredIcons: "Some selected icons are in macOS’s overflow or covered by another window. Expand them with the menu bar’s chevron, then reopen NookBar."
            case .overflowRestore: "The native overflow bar could not be restored after capture. Apps have been left visible; close the overflow bar and try again."
            }
        }
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
