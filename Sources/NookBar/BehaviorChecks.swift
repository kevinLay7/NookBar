import AppKit

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
        let image = NSImage(size: NSSize(width: 20, height: 20))
        let icons = [
            HiddenBar.Icon(bundle: "example.amphetamine", index: 0, label: "∞", appName: "Amphetamine", image: image),
            HiddenBar.Icon(bundle: "example.stats", index: 0, label: "CPU", appName: "Stats", image: image),
            HiddenBar.Icon(bundle: "example.stats", index: 1, label: "RAM", appName: "Stats", image: image),
            HiddenBar.Icon(bundle: "example.cafe", index: 0, label: "Café", appName: "Café", image: image)
        ]
        check(HiddenBar.matchingIndices(in: icons, query: "AMPH") == [0], "search finds app name behind a symbol-only icon")
        check(HiddenBar.matchingIndices(in: icons, query: " stats ") == [1, 2], "search preserves separate icons from one app")
        check(HiddenBar.matchingIndices(in: icons, query: "cafe") == [3], "search ignores accents")
        check(HiddenBar.matchingIndices(in: icons, query: "not installed").isEmpty, "missing query has no false match")
        print("Behavior checks passed: activation, rehide, persistence, shortcut validation, and icon search.")
    }
}
