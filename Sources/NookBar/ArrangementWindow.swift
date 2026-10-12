import AppKit
@preconcurrency import NativeMenuBar

@MainActor
final class ArrangementWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private let table = NSTableView()
    private let screenPicker = NSPopUpButton()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let sectionNote = NSTextField(wrappingLabelWithString: "")
    private let movement = MenuBarMovement()
    private var entries: [NBMenuBarEntry] = []
    private var images: [Int: NSImage] = [:]
    private var captureIssues: [Int: String] = [:]
    private var captureTask: Task<Void, Never>?
    private var screens: [NSScreen] = []
    private var buttons: [NSButton] = []
    private var generation = 0
    private var moveTask: Task<Void, Never>?
    private let dragType = NSPasteboard.PasteboardType("com.codenest.nookbar.arrangement")
    var onClose: (() -> Void)?
    // The host supplies both storage and the application callback. Without both,
    // the picker is read-only and does not claim that membership is implemented.
    var sections: AppSections?
    var onAssignIcon: ((NBMenuBarEntry, AppSections.Section?, [NBMenuBarEntry]) -> String?)?
    var sectionApplicationNote = "Individual icon assignments are unavailable until the section backend is connected."

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "NookBar — Arrange Icons"
        window.minSize = NSSize(width: 650, height: 460)
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
        let intro = NSTextField(wrappingLabelWithString: "Drag rows to arrange icons from left to right in the menu bar. All apps stay visible while this window is open. Closing it restores your hiding settings. Use Section to choose Visible, Hidden, or Always Hidden for an individual icon. Use App Setting removes its override.")
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        screenPicker.target = self; screenPicker.action = #selector(refreshFromButton)
        screenPicker.setAccessibilityLabel("Display to arrange")
        stack.addArrangedSubview(screenPicker)
        sectionNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sectionNote)
        sectionNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        column.title = "Menu bar order · left to right"
        column.minWidth = 270; column.width = 420
        table.addTableColumn(column)
        let sectionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        sectionColumn.title = "Section"
        sectionColumn.width = 230; sectionColumn.minWidth = 230; sectionColumn.maxWidth = 230
        sectionColumn.resizingMask = []
        table.addTableColumn(sectionColumn); table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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
        sectionNote.stringValue = sectionApplicationNote
        let request = generation
        captureTask?.cancel()
        entries = []; images = [:]; captureIssues = [:]; table.reloadData()
        guard screens.indices.contains(screenPicker.indexOfSelectedItem) else { feedback.stringValue = "No display is available."; return }
        let screen = screens[screenPicker.indexOfSelectedItem]
        entries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen))
        table.reloadData()
        feedback.stringValue = entries.isEmpty ? "No icons found. Enable Accessibility access, show the menu bar, then refresh." : "Select an icon, then drag its row or use Move Left / Move Right. System icons are not supported yet."
        updateButtons()
        let capturedEntries = entries
        guard !capturedEntries.isEmpty else { return }
        captureTask = Task {
            var loaded: [Int: NSImage] = [:]
            var failures: [Int: String] = [:]
            let permitted = CGPreflightScreenCaptureAccess()
            for (row, entry) in capturedEntries.enumerated() {
                guard !Task.isCancelled, request == generation, isVisible else { return }
                guard permitted else {
                    failures[row] = "Screen Recording access is not enabled."
                    continue
                }
                guard NBMenuBarEntryProcessKey(entry) != nil else {
                    failures[row] = "This icon has no verified running process identity; its image cannot be captured safely."
                    continue
                }
                do {
                    let icons = try await HiddenBar.capture(entries: [entry])
                    guard !Task.isCancelled, request == generation, isVisible else { return }
                    guard icons.count == 1, let captured = icons[0].entry,
                          NBSameMenuBarEntryDescriptor(entry, captured) else {
                        failures[row] = "This icon changed during capture. Refresh to try again."
                        continue
                    }
                    loaded[row] = icons[0].image
                } catch {
                    guard !Task.isCancelled, request == generation, isVisible else { return }
                    failures[row] = error.localizedDescription
                }
            }
            guard !Task.isCancelled, request == generation, isVisible else { return }
            images = loaded
            captureIssues = failures
            captureTask = nil
            let selected = table.selectedRowIndexes
            table.reloadData()
            table.selectRowIndexes(selected, byExtendingSelection: false)
            if !failures.isEmpty {
                let reasons = Dictionary(grouping: failures.values, by: { $0 })
                    .map { "\($0.value.count): \($0.key)" }.sorted().joined(separator: " ")
                sectionNote.stringValue = "\(sectionApplicationNote)\n\(loaded.count) of \(capturedEntries.count) icon images loaded; \(failures.count) unavailable. \(reasons)"
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        if tableColumn?.identifier.rawValue == "section" { return sectionPicker(for: entry, row: row) }
        let cell = NSTableCellView()
        let image = NSImageView(); image.imageScaling = .scaleProportionallyDown
        image.image = images[row]
        image.translatesAutoresizingMaskIntoConstraints = false
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundle).first?.localizedName ?? entry.bundle
        let label = NSTextField(labelWithString: app == entry.label ? app : "\(app) — \(entry.label)")
        label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(label); cell.imageView = image; cell.textField = label
        cell.setAccessibilityLabel(label.stringValue)
        if let issue = captureIssues[row] {
            cell.toolTip = issue
            cell.setAccessibilityHelp("Icon image unavailable. \(issue)")
        }
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
    private func sectionPicker(for entry: NBMenuBarEntry, row: Int) -> NSView {
        let cell = NSView()
        let picker = NSPopUpButton()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.addItems(withTitles: AppSections.Section.allCases.map(\.title))
        picker.menu?.addItem(.separator())
        let fallback = sections?.section(for: entry.bundle) ?? .visible
        picker.addItem(withTitle: "Use App Setting (\(fallback.title))")
        picker.tag = row
        // Reloads invalidate stale popups even when their row number is reused.
        picker.identifier = NSUserInterfaceItemIdentifier("\(generation)")
        picker.target = self; picker.action = #selector(assignSection(_:))
        if let sections {
            if let saved = sections.iconSectionOverride(for: entry, among: entries) {
                if saved == sections.section(for: entry, among: entries, checkCurrent: false) {
                    picker.selectItem(at: AppSections.Section.allCases.firstIndex(of: saved) ?? 0)
                } else {
                    // Saved membership may be pending identity confirmation after
                    // an app restart. Never label its effective fallback as saved.
                    picker.addItem(withTitle: "Saved \(saved.title) (Confirm)")
                    picker.selectItem(at: 5)
                }
            } else {
                picker.selectItem(at: 4)
            }
        }
        if sections == nil {
            picker.addItem(withTitle: "Unavailable")
            picker.selectItem(at: 5)
        }
        let issue = sectionAssignmentIssue(for: entry)
        picker.isEnabled = moveTask == nil && issue == nil
        picker.toolTip = issue ?? "Choose a section for this icon. Use App Setting removes this icon’s override. The app setting is \(fallback.title); unresolved icon identities keep icons visible."
        picker.setAccessibilityLabel("Section for \(entry.label)")
        picker.setAccessibilityHelp(picker.toolTip)
        cell.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            picker.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            picker.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    // Drawing and selection callbacks must inspect only the retained snapshot.
    // Live AX validation belongs to the host's assignment callback after the
    // action has collected a fresh inventory, never to table rendering.
    private func sectionAssignmentIssue(for entry: NBMenuBarEntry) -> String? {
        guard let sections, onAssignIcon != nil else { return "Individual icon assignments are not connected yet." }
        guard !entry.bundle.hasPrefix("com.apple."), entry.bundle != "com.codenest.nookbar" else {
            return "Section assignment is not supported for system icons or NookBar controls."
        }
        guard let key = NBMenuBarEntryPreferenceKey(entry), !key.isEmpty else {
            return "This icon has no persistent descriptor. Its section cannot be assigned safely."
        }
        guard entries.filter({ NBMenuBarEntryPreferenceKey($0) == key }).count == 1 else {
            return "Several icons have the same descriptor. Their sections cannot be assigned independently."
        }
        return sections.iconAssignmentIssue(for: entry, among: entries, checkCurrent: false)
    }
    @objc private func assignSection(_ sender: NSPopUpButton) {
        guard moveTask == nil, sender.identifier?.rawValue == "\(generation)", entries.indices.contains(sender.tag),
              let callback = onAssignIcon else { return }
        let entry = entries[sender.tag]
        if let issue = sectionAssignmentIssue(for: entry) {
            feedback.stringValue = issue
            table.reloadData()
            return
        }
        let index = sender.indexOfSelectedItem
        guard AppSections.Section.allCases.indices.contains(index) || index == 4 else { return }
        let section = index == 4 ? nil : AppSections.Section.allCases[index]
        guard screens.indices.contains(screenPicker.indexOfSelectedItem) else {
            feedback.stringValue = "The display is no longer available. Refresh before assigning a section."
            return
        }
        // A retained row is not proof that its descriptor still exists. Keep
        // the original entry for identity comparison against a fresh inventory.
        let screen = screens[screenPicker.indexOfSelectedItem]
        let liveEntries = NBMenuBarEntries(HiddenBar.captureFrame(for: screen))
        if let issue = callback(entry, section, liveEntries) {
            feedback.stringValue = issue
            table.reloadData()
            return
        }
        table.reloadData()
        feedback.stringValue = "\(entry.label): \(sections?.section(for: entry, among: liveEntries, checkCurrent: false).title ?? "Visible"). \(sectionApplicationNote)"
    }
    private func movable(_ row: Int) -> Bool { entries.indices.contains(row) && !entries[row].bundle.hasPrefix("com.apple.") }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard moveTask == nil, entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        if let issue = sectionAssignmentIssue(for: entry) {
            feedback.stringValue = "\(entry.label): \(issue)"
        } else if let captureIssue = captureIssues[table.selectedRow] {
            feedback.stringValue = "\(entry.label): icon image unavailable. \(captureIssue)"
        } else if let sections, let saved = sections.iconSectionOverride(for: entry, among: entries),
                  saved != sections.section(for: entry, among: entries, checkCurrent: false) {
            feedback.stringValue = "\(entry.label): saved \(saved.title) is pending identity confirmation. Choose the section again to confirm this icon."
        }
    }
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
        table.reloadData()
    }
    func cancel() {
        generation += 1
        moveTask?.cancel()
        captureTask?.cancel(); captureTask = nil
        movement.cancel()
    }
    func close() { cancel(); window?.close() }
    func windowWillClose(_ notification: Notification) { cancel(); onClose?() }
}
