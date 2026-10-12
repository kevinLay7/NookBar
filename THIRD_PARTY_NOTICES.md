# Research and adapted code

The native bridge adapts Accessibility discovery and runtime dispatch from
[Ice 2](https://github.com/teddychan/ice-2), specifically
`Ice/MenuBar/Native/NativeMenuBarBridge.m` and `scripts/macos27-prototype.m`.
Copyright (C) 2026 Teddy Chan. Ice 2 builds on Ice, copyright (C) 2024 Jordan Baird.
Both are licensed under GPL-3.0-or-later. NookBar preserves that license.

Ice 2 credits [Pelmet](https://github.com/fif7y/pelmet), GPL-3.0, for research into
Apple's undocumented MenuBarClientCore selectors and Accessibility tree shape.

The appearance configuration and renderer adapt shape geometry, tint opacity,
border clipping, and shadow behavior from [Ice](https://github.com/jordanbaird/Ice),
commit `da2dd23cdd70d287445cbe3dbb5628a4c3ad8c7e`, especially
`Ice/MenuBar/Appearance/Configurations` and
`Ice/MenuBar/Appearance/MenuBarOverlayPanel.swift`.
Copyright (C) 2024 Jordan Baird. Licensed under GPL-3.0-or-later.
NookBar uses its own native settings interface and a ScreenCaptureKit wallpaper
strip rather than Ice’s wallpaper capture implementation.

The menu bar spacing preference keys, base value, and offset range follow
Ice’s `Ice/MenuBar/Spacing/MenuBarItemSpacingManager.swift` at the same commit.
Copyright (C) 2024 Jordan Baird, GPL-3.0-or-later. NookBar uses CFPreferences,
transaction rollback, a persisted restoration snapshot, and an explicit app
selection dialog with graceful quit requests.

The three-second image refresh cadence while the strip/search is displayed follows
Ice's `Ice/MenuBar/MenuBarItems/MenuBarItemImageCache.swift` at the same commit.
Copyright (C) 2024 Jordan Baird, GPL-3.0-or-later. NookBar uses its own region
capture and in-place view update; Ice's per-window capture implementation is not
used here.

Native item click state and temporary-interface window tracking follow Ice's
`Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift` at the same commit, especially
its click event creation and `TemporarilyShownItemContext` lifetime rules.
Copyright (C) 2024 Jordan Baird, GPL-3.0-or-later. NookBar uses hit-checked event
posting and records the first new owning-process window after activation; it
does not use Ice's window-ID event barrier implementation.

The temporary-show delay, range, and interface/input retry intervals follow
Ice's `AdvancedSettings.swift`, `AdvancedSettingsPane.swift`, `MouseHelpers.swift`,
and `MenuBarItemManager.swift` at the same commit. Copyright (C) 2024 Jordan
Baird, GPL-3.0-or-later. NookBar uses native field/stepper controls and a monotonic
deadline with the same input-pause conditions.

Icon search adapts the Fuse and best-match algorithms from
[Ifrit](https://github.com/ukushu/Ifrit), version 2.0.6, commit
`3f961f6d39cd2188305671f2ec65914d297571d0`, which Ice uses for search ranking.
The applicable copyright notices and MIT/Apache-2.0 license texts are preserved
in [LICENSES/IconSearch.txt](LICENSES/IconSearch.txt). NookBar's implementation
also searches bundle identifiers, folds accents, and handles long patterns.

These projects are not runtime dependencies. The adapted bridge is compiled
as part of NookBar. Apple framework names describe system dependencies and do
not imply Apple's endorsement.
