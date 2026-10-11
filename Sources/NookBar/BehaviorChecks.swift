import AppKit
@preconcurrency import NativeMenuBar

@MainActor
enum BehaviorChecks {
    static func run() {
        let suite = "NookBar.BehaviorChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
        }
        // Opening by keyboard must not immediately close because the pointer is
        // already outside. Entering then leaving the bar permits smart rehide.
        check(!preferences.shouldRehide(elapsed: 100, inside: false, pointerEntered: false), "keyboard opening remains usable")
        check(!preferences.shouldRehide(elapsed: 100, inside: true, pointerEntered: true), "bar remains usable under pointer")
        check(preferences.shouldRehide(elapsed: 1, inside: false, pointerEntered: true), "smart rehide after leaving")
        defaults.set("timed", forKey: "rehideStrategy")
        defaults.set(10, forKey: "rehideInterval")
        check(!preferences.shouldRehide(elapsed: 9, inside: false, pointerEntered: true), "timer does not rehide early")
        check(preferences.shouldRehide(elapsed: 10, inside: true, pointerEntered: false), "timed strategy uses its deadline")
        defaults.set(false, forKey: "autoRehide")
        check(!preferences.shouldRehide(elapsed: 100, inside: false, pointerEntered: true), "disabled auto rehide stays disabled")
        defaults.set(true, forKey: "autoRehide")
        defaults.set("focusedApp", forKey: "rehideStrategy")
        check(!preferences.shouldRehide(elapsed: 100, inside: false, pointerEntered: true), "focused-app strategy does not use a timer")
        defaults.set("unknown", forKey: "rehideStrategy")
        defaults.set(-5, forKey: "hoverDelay")
        defaults.set(5000, forKey: "rehideInterval")
        check(preferences.rehide == .smart && preferences.hoverDelay == 0 && preferences.rehideInterval == 300, "corrupt or out-of-range preferences are bounded")
        let shortcut = Shortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.union(.option).rawValue, key: "k")
        preferences.setShortcut(shortcut, for: .search)
        check(shortcut.matches(keyCode: 40, flags: [.command, .option, .capsLock]), "Caps Lock does not disable a shortcut")
        check(!shortcut.matches(keyCode: 40, flags: [.command, .option, .shift]), "additional modifiers do not trigger the wrong action")
        check(Preferences(defaults: defaults).shortcut(.search) == shortcut, "shortcut persists across launches")
        check(!Shortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags.shift.rawValue, key: "k").valid, "ordinary typing cannot become a global shortcut")
        preferences.setShortcut(nil, for: .search)
        check(preferences.shortcut(.search) == nil, "clearing shortcut removes its registration settings")
        defaults.set(["example.one", "example.two", "com.apple.controlcenter", "com.codenest.nookbar"], forKey: "HiddenApps")
        defaults.set(["example.two"], forKey: "AlwaysHiddenApps")
        let sections = AppSections(defaults: defaults)
        check(sections.hidden == ["example.one"] && sections.alwaysHidden == ["example.two"], "always-hidden membership wins and system/control icons stay visible")
        sections.assign("example.one", to: .alwaysHidden)
        check(sections.hidden.isEmpty && sections.alwaysHidden == ["example.one", "example.two"], "moving between sections has no duplicate membership")
        sections.hideAll(["example.one", "example.three"])
        check(sections.hidden == ["example.three"] && sections.alwaysHidden.contains("example.one"), "select all preserves always-hidden membership")
        sections.assign("example.one", to: .visible)
        let restoredSections = AppSections(defaults: defaults)
        check(restoredSections.section(for: "example.one") == .visible && restoredSections.section(for: "example.two") == .alwaysHidden && restoredSections.tucked == ["example.two", "example.three"], "sections persist and visible membership clears hiding")
        sections.clear()
        check(AppSections(defaults: defaults).tucked.isEmpty, "clear selection clears both hidden sections")
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let icons = [
            HiddenBar.Icon(bundle: "example.amphetamine", entry: nil, label: "∞", appName: "Amphetamine", image: image),
            HiddenBar.Icon(bundle: "example.stats", entry: nil, label: "CPU", appName: "Stats", image: image),
            HiddenBar.Icon(bundle: "example.stats", entry: nil, label: "RAM", appName: "Stats", image: image),
            HiddenBar.Icon(bundle: "example.cafe", entry: nil, label: "Café", appName: "Café", image: image)
        ]
        check(HiddenBar.matchingIndices(in: icons, query: "AMPH") == [0], "search finds app name behind a symbol-only icon")
        check(HiddenBar.matchingIndices(in: icons, query: " stats ") == [1, 2], "search preserves separate icons from one app")
        check(HiddenBar.matchingIndices(in: icons, query: "cafe") == [3], "search ignores accents")
        check(HiddenBar.matchingIndices(in: icons, query: "not installed").isEmpty, "missing query has no false match")
        let unavailableEntry = NBMenuBarEntry()
        check(!NBSameMenuBarEntry(unavailableEntry, unavailableEntry), "an entry without live AX identity cannot match itself")
        check(NBResolveMenuBarEntry(unavailableEntry, CGRect(x: 0, y: 0, width: 100, height: 39)) == nil, "a missing identity never resolves by ordinal or label")
        check(ArrangementWindow.instancesRespond(to: NSSelectorFromString("tableView:pasteboardWriterForRow:")) && ArrangementWindow.instancesRespond(to: NSSelectorFromString("tableView:acceptDrop:row:dropOperation:")), "native table exposes its drag source and drop handlers")
        let source = CGRect(x: 100, y: 5, width: 24, height: 24)
        let target = CGRect(x: 150, y: 5, width: 24, height: 24)
        let menuBar = CGRect(x: 0, y: 0, width: 300, height: 39)
        check((try? MenuBarMovement.destination(source: source, target: target, before: true, menuBar: menuBar)) == CGPoint(x: 148, y: 17), "move before target stays inside the menu bar")
        check((try? MenuBarMovement.destination(source: source, target: target, before: false, menuBar: menuBar)) == CGPoint(x: 176, y: 17), "move after target stays inside the menu bar")
        check((try? MenuBarMovement.destination(source: source, target: source, before: true, menuBar: menuBar)) == nil, "overlapping identities cannot start a drag")
        check((try? MenuBarMovement.destination(source: source, target: CGRect(x: 299, y: 5, width: 24, height: 24), before: false, menuBar: menuBar)) == nil, "offscreen destinations cannot start a drag")
        check((try? MenuBarMovement.destination(source: source, target: CGRect(x: 150, y: 55, width: 24, height: 24), before: true, menuBar: menuBar)) == nil, "another vertical region cannot become a menu bar destination")
        check(ArrangementWindow.targetForDrop(source: 2, row: 0, count: 4)?.index == 0, "upward drop uses the intended neighbor")
        check(ArrangementWindow.targetForDrop(source: 0, row: 4, count: 4)?.before == false, "end drop places after the last neighbor")
        check(ArrangementWindow.targetForDrop(source: 2, row: 3, count: 4) == nil, "dropping immediately after self is a no-op")
        check(ArrangementWindow.targetForDrop(source: -1, row: 0, count: 4) == nil && ArrangementWindow.targetForDrop(source: 0, row: 5, count: 4) == nil, "invalid row payloads do not target another icon")
        var appearance = AppearanceConfiguration()
        appearance.dynamic = true; appearance.dark.border = true; appearance.light.tint = .solid
        appearance.dark.borderWidth = 500
        appearance.light.tintColor = AppearanceColor(red: -1, green: .infinity, blue: 2)
        appearance.light.stops = [AppearanceStop(color: .black, location: 2), AppearanceStop(color: .white, location: -1)]
        appearance.save(to: defaults)
        let restoredAppearance = AppearanceConfiguration.load(from: defaults)
        check(restoredAppearance.style(dark: true).border && !restoredAppearance.style(dark: false).border && restoredAppearance.light.tint == .solid, "light and dark appearance profiles persist independently")
        check(restoredAppearance.dark.borderWidth == 3 && restoredAppearance.light.tintColor == AppearanceColor(red: 0, green: 0, blue: 1) && restoredAppearance.light.stops.map(\.location) == [0, 1], "appearance input and gradient positions are bounded")
        defaults.set(Data("invalid".utf8), forKey: "MenuBarAppearance")
        check(AppearanceConfiguration.load(from: defaults).shape == .none && !AppearanceConfiguration.load(from: defaults).standard.hasEffect, "unreadable appearance settings restore an unchanged menu bar")
        appearance = AppearanceConfiguration(); appearance.shape = .split
        let barBounds = CGRect(x: 0, y: 5, width: 1000, height: 39)
        let pieces = appearance.pieces(in: barBounds, menuWidth: 300, iconStart: 700, hasNotch: true)
        check(pieces.count == 2 && !pieces[0].rect.intersects(pieces[1].rect) && pieces[0].rect.minY == 8.5 && pieces[0].rect.height == 32, "split appearance leaves a gap and applies the notch inset")
        let path = AppearanceConfiguration.path(for: pieces)
        check(path.contains(CGPoint(x: 100, y: 20)) && !path.contains(CGPoint(x: 500, y: 20)) && path.contains(CGPoint(x: 900, y: 20)), "split appearance path covers menus and icons without painting the gap")
        check(appearance.pieces(in: barBounds, menuWidth: 800, iconStart: 700, hasNotch: true).count == 1 && appearance.pieces(in: barBounds, menuWidth: nil, iconStart: 700, hasNotch: true).count == 1, "overlapping or missing split geometry falls back to the full shape")
        appearance.shape = .full; appearance.full.left = .square
        let square = AppearanceConfiguration.path(for: appearance.pieces(in: barBounds, menuWidth: nil, iconStart: nil, hasNotch: true))
        check(square.contains(CGPoint(x: 1, y: 9)) && !square.contains(CGPoint(x: 996, y: 9)), "independent square and round end caps preserve their geometry")
        let spacingDomain = "com.codenest.nookbar.spacing-check.\(UUID().uuidString)" as CFString
        let spacingBefore = try! MenuBarSpacingValues(domain: spacingDomain)
        defer { try? spacingBefore.apply(domain: spacingDomain) }
        check(spacingBefore.spacing == nil && spacingBefore.padding == nil, "spacing check starts with an isolated host-specific domain")
        try! MenuBarSpacingValues(offset: -8).apply(domain: spacingDomain)
        let compact = try! MenuBarSpacingValues(domain: spacingDomain)
        check(compact.offset == -8 && compact.spacing == compact.padding, "spacing writes and reads both host-specific preferences")
        let savedSpacing = try! JSONEncoder().encode(compact)
        try! MenuBarSpacingValues(offset: 16).apply(domain: spacingDomain)
        check(try! MenuBarSpacingValues(domain: spacingDomain).offset == 16, "widest spacing survives native preference round trip")
        try! JSONDecoder().decode(MenuBarSpacingValues.self, from: savedSpacing).apply(domain: spacingDomain)
        check(try! MenuBarSpacingValues(domain: spacingDomain) == compact, "spacing backup restores the prior native values")
        var customSpacing = try! MenuBarSpacingValues(offset: 8)
        customSpacing.padding = compact.padding
        check(customSpacing.offset == nil, "mismatched system spacing is labeled custom")
        try! customSpacing.apply(domain: spacingDomain)
        let customBackup = try! JSONEncoder().encode(MenuBarSpacingValues(domain: spacingDomain))
        try! MenuBarSpacingValues(offset: 0).apply(domain: spacingDomain)
        try! JSONDecoder().decode(MenuBarSpacingValues.self, from: customBackup).apply(domain: spacingDomain)
        check(try! MenuBarSpacingValues(domain: spacingDomain) == customSpacing, "custom prior preferences restore exactly instead of becoming a default")
        try! compact.apply(domain: spacingDomain)
        var invalidSpacing = try! MenuBarSpacingValues(offset: 8)
        invalidSpacing.padding = Data("invalid property list".utf8)
        check((try? invalidSpacing.apply(domain: spacingDomain)) == nil, "invalid second preference rejects a spacing transaction")
        check(try! MenuBarSpacingValues(domain: spacingDomain) == compact, "partial spacing write rolls both preferences back")
        try! MenuBarSpacingValues(offset: 0).apply(domain: spacingDomain)
        check(try! MenuBarSpacingValues(domain: spacingDomain) == spacingBefore, "default spacing removes both host-specific overrides")
        check((try? MenuBarSpacingValues(offset: -17)) == nil && (try? MenuBarSpacingValues(offset: 3)) == nil, "spacing rejects out-of-range and non-step values")
        print("Behavior checks passed: activation, rehide, sections, shortcuts, search, arrangement, appearance persistence/geometry, and native spacing preferences.")
    }
}
