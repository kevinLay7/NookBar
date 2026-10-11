# Application-menu ownership investigation

Environment: macOS 27.0.1 (26A434), October 11, 2026.

Ice's application-menu feature activates its process with a regular activation
policy and hides its main-menu items. NookBar still needs automatic space-aware
menu replacement and restoration. This investigation did not produce a working
replacement, so its experimental controls were removed from the installed app.

## Controlled experiment

An experimental Advanced button requested regular activation, assigned an
AppKit main menu, and activated NookBar. It saved the old menu/policy and tracked
the previously focused external application. A delayed check required both
NookBar activation and actual menu bar ownership; failure restored the saved
state. Switching applications also restored the state.

Variants tested through CUA on the signed installed app included:

- Empty menu, hidden application-menu root, and visible application-menu root.
- Assigning the menu before changing activation policy.
- NSApplication activation and NSRunningApplication activation from the prior app.
- LSUIElement enabled and disabled, retaining accessory policy during ordinary use.
- Registering a main menu and regular policy before entering the app run loop.
- Deactivating before requesting activation again.

The button immediately changed to Restore, but that was insufficient evidence.
A diagnostic recorded `NSApp.isActive == true`, regular policy, and NookBar as
frontmost while `NSWorkspace.menuBarOwningApplication` remained Hopper.
Independent metadata still identified Hopper as menu bar owner, with its full
menu titles. The settled ownership check restored the button to Hide. Extending
the check to three seconds did not establish successful ownership in these tests.

This establishes failure of these variants under this test setup. It does not
prove that macOS disallows application-menu replacement, or that every physical
activation path behaves identically. It does not validate automatic room
calculation, Dock behavior, or restoration after a successful replacement.

The experimental source was retained outside the public app for follow-up.
The installed app was rebuilt from the validated source with LSUIElement enabled;
its existing build, signature, diagnostics, and behavior checks passed. Existing
app sections and user settings were preserved.

## Next checks

1. Compare Ice's initial menu registration and activation lifecycle with the
   AppKit implementation, including the menu bar agent's ownership transition.
2. Verify a successful replacement with actual rendered menu titles and native
   ownership before adding a public control or automatic behavior.
3. Verify explicit restore, application switching, quit, failure, Dock visibility,
   fullscreen, and each display, then add automatic room management.
