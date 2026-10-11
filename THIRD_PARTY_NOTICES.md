# Research and adapted code

The native bridge adapts Accessibility discovery and runtime dispatch from
[Ice 2](https://github.com/teddychan/ice-2), specifically
`Ice/MenuBar/Native/NativeMenuBarBridge.m` and `scripts/macos27-prototype.m`.
Copyright (C) 2026 Teddy Chan. Ice 2 builds on Ice, copyright (C) 2024 Jordan Baird.
Both are licensed under GPL-3.0-or-later. NookBar preserves that license.

Ice 2 credits [Pelmet](https://github.com/fif7y/pelmet), GPL-3.0, for research into
Apple's undocumented MenuBarClientCore selectors and Accessibility tree shape.

These projects are not runtime dependencies. The adapted bridge is compiled
as part of NookBar. Apple framework names describe system dependencies and do
not imply Apple's endorsement.
