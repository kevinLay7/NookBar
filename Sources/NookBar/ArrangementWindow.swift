import AppKit
@preconcurrency import NativeMenuBar

@MainActor
final class ArrangementWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private let table = NSTableView()
    private let screenPicker = NSPopUpButton()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let movement = MenuBarMovement()
    private var entries: [NBMenuBarEntry] = []
    private var images: [NSImage] = []
    private var screens: [NSScreen] = []
    private var buttons: [NSButton] = []
    private var generation = 0
    private var moveTask: Task<Void, Never>?
    private let dragType = NSPasteboard.PasteboardType("com.codenest.nookbar.arrangement")
    var onClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { makeWindow() }
        screens = NSScreen.screens
        screenPicker.removeAllItems()
        screenPicker.addItems(withTitles: screens.map(\.localizedName))
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        let request = generation
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if request == generation, isVisible, moveTask == nil { refresh() }
        }
    }
    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "NookBar — Arrange Icons"
        window.minSize = NSSize(width: 530, height: 430)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        let intro = NSTextField(wrappingLabelWithString: "Drag rows to arrange icons from left to right in the menu bar. All apps stay visible while this window is open. Closing it restores your hiding settings. Section assignments currently apply to whole apps.")
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        screenPicker.target = self; screenPicker.action = #selector(refreshFromButton)
        screenPicker.setAccessibilityLabel("Display to arrange")
        stack.addArrangedSubview(screenPicker)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        column.title = "Menu bar order · left to right"
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 42; table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Menu bar icons in left to right order")
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let controls = NSStackView(); controls.spacing = 8
        for (title, action) in [("Move Left", #selector(moveLeft)), ("Move Right", #selector(moveRight)), ("Refresh", #selector(refreshFromButton))] {
            let button = NSButton(title: title, target: self, action: action)
            buttons.append(button); controls.addArrangedSubview(button)
        }
        stack.addArrangedSubview(controls)
        feedback.textColor = .secondaryLabelColor
        stack.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.window = window
    }
    @objc private func refreshFromButton() { refresh() }
    func refresh() {
        guard moveTask == nil else { return }
        generation += 1
        let request = generation
        entries = []; images = []; table.reloadData()
        guard screens.indices.contains(screenPicker.indexOfSelectedItem) else { feedback.stringValue = "No display is available."; return }
        let screen = screens[screenPicker.indexOfSelectedItem]
        entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen))
        table.reloadData()
        feedback.stringValue = entries.isEmpty ? "No icons found. Enable Accessibility access, show the menu bar, then refresh." : "Select an icon, then drag its row or use Move Left / Move Right. System icons are not supported yet."
        updateButtons()
        let capturedEntries = entries
        Task {
            do {
                let icons = try await HiddenBar.capture(entries: capturedEntries)
                guard request == generation, isVisible else { return }
                images = icons.map(\.image)
                let selected = table.selectedRowIndexes
                table.reloadData()
                table.selectRowIndexes(selected, byExtendingSelection: false)
            } catch {
                guard request == generation, isVisible else { return }
                feedback.stringValue = "Icon images could not be captured. Check Screen Recording access. Names remain available for arranging."
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        let image = NSImageView(); image.imageScaling = .scaleProportionallyDown
        if images.indices.contains(row) { image.image = images[row] }
        image.translatesAutoresizingMaskIntoConstraints = false
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundle).first?.localizedName ?? entry.bundle
        let label = NSTextField(labelWithString: app == entry.label ? app : "\(app) — \(entry.label)")
        label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(label); cell.imageView = image; cell.textField = label
        cell.setAccessibilityLabel(label.stringValue)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 50), image.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    private func movable(_ row: Int) -> Bool { entries.indices.contains(row) && !entries[row].bundle.hasPrefix("com.apple.") }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        guard buttons.count == 3 else { return }
        let row = table.selectedRow, idle = moveTask == nil
        buttons[0].isEnabled = idle && movable(row) && row > 0 && movable(row - 1)
        buttons[1].isEnabled = idle && movable(row) && row + 1 < entries.count && movable(row + 1)
        buttons[2].isEnabled = idle
        screenPicker.isEnabled = idle
    }
    @objc private func moveLeft() { beginMove(from: table.selectedRow, to: table.selectedRow - 1, before: true) }
    @objc private func moveRight() { beginMove(from: table.selectedRow, to: table.selectedRow + 1, before: false) }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard moveTask == nil, movable(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(generation):\(row)", forType: dragType)
        return item
    }
    private func dragRow(_ info: NSDraggingInfo) -> Int? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              let text = info.draggingPasteboard.string(forType: dragType) else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 2, Int(parts[0]) == generation, let row = Int(parts[1]), movable(row) else { return nil }
        return row
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard moveTask == nil, dragRow(info) != nil, row >= 0, row <= entries.count else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        let target = row == entries.count ? row - 1 : row
        return movable(target) ? .move : []
    }
    static func targetForDrop(source: Int, row: Int, count: Int) -> (index: Int, before: Bool)? {
        guard source >= 0, source < count, row >= 0, row <= count,
              row != source, row != source + 1 else { return nil }
        return (row == count ? row - 1 : row, row != count)
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = dragRow(info), row >= 0, row <= entries.count else { return false }
        if row == source || row == source + 1 { return true }
        guard let target = Self.targetForDrop(source: source, row: row, count: entries.count) else { return false }
        beginMove(from: source, to: target.index, before: target.before)
        return true
    }
    private func beginMove(from sourceIndex: Int, to targetIndex: Int, before: Bool) {
        guard moveTask == nil, movable(sourceIndex), movable(targetIndex), sourceIndex != targetIndex,
              screens.indices.contains(screenPicker.indexOfSelectedItem) else { return }
        let source = entries[sourceIndex], target = entries[targetIndex]
        let screen = screens[screenPicker.indexOfSelectedItem]
        generation += 1
        feedback.stringValue = "Moving \(source.label)…"
        moveTask = Task {
            var message = "Icon moved. macOS preserves its menu bar position."
            do { try await movement.move(source, beside: target, before: before, screen: screen) }
            catch is CancellationError { message = "Movement cancelled. Refresh before continuing." }
            catch { message = error.localizedDescription }
            moveTask = nil
            guard isVisible else { return }
            refresh()
            if let row = entries.firstIndex(where: { NBSameMenuBarEntry($0, source) }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            feedback.stringValue = message
        }
        updateButtons()
    }
    func cancel() {
        generation += 1
        moveTask?.cancel()
        movement.cancel()
    }
    func close() { cancel(); window?.close() }
    func windowWillClose(_ notification: Notification) { cancel(); onClose?() }
}
