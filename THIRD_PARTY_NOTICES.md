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

These projects are not runtime dependencies. The adapted bridge is compiled
as part of NookBar. Apple framework names describe system dependencies and do
not imply Apple's endorsement.
