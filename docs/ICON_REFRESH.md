# Changing menu bar icons

Ice's image cache refreshes every three seconds while relevant UI is visible.
NookBar now captures on each opening and refreshes the displayed strip/search
every three seconds while idle. It updates the existing panel, retaining search
text, selected identity, and scroll position rather than reopening the window.

AXHelp is presentation text, not a primary descriptor. Macs Fan Control has no
title, description, or identifier and puts its changing RPM values in AXHelp.
Resolution now compares AX/process identity and identifier/description/title,
allowing tooltip changes. Primary descriptor changes still reject resolution.
Same-label replacement isolation remains unproven because macOS can reuse AX
identities. Replacing unlabeled items has the same underlying limitation.

On the built-in display on macOS 27.0.1, the signed installed app passed native
hide/reveal, removal, primary-label rename, and live-entry resolution checks,
including a changed Macs Fan Control tooltip. An owned changing SF Symbol probe
passed two capture/update cycles with different image pixels and the same panel
remaining visible. CUA showed the ordinary seven-app strip's fan readings update;
search retained the query `fan` while readings changed from 2341/2066 to 2330/2055
RPM. The subsequent CUA activation attempt timed out, so foreign menu activation
after refresh is not established by this check.

The developer-only `--refresh-check --report PATH` captures owned test icons,
changes their images twice, updates the actual panel, and compares each icon's
independently rendered pixel buffer by its Accessibility descriptor. Combine it
with `--overflow-probe` to exercise 24 overflow icons while the panel is open.
The probe changes all images to SF Symbols 49, then 50, so every image must
change in each cycle. The original identity, count, visible panel, and collapsed
overflow restoration must all survive. This diagnostic does not exercise the
application's three-second timer; the ordinary strip/search observations above
exercise that path. `--refresh-hold` pauses at each change for independent
inspection and writes a stage into the report; an intermediate stage is not a
completed test result.

## Discovery exhaustion

The initial combined test failed after showing the strip. Its artificial anchor
was at the screen's top edge, covering the chevron; it now uses the ordinary
pointer anchor below the menu bar. Correcting the anchor left a second failure:
discovery returned zero entries even though the native control remained exposed.
An independent raw AX walk still found all 24 owned probe entries, with valid
frames, while a research build with a larger budget counted 4,690 traversal
visits and normalized 55 collected entries to 43 entries (25 owned, including
the control). The production limit was 4,096 visits, and exhaustion returned an
empty result. This was repeated subtree traversal, not proof of missing icons.

Discovery now caches the shallowest visit to each AX element/group-region pair
within one query. It preserves separate region checks and separate inactive
system-item identities, and allows a later shallower path to revisit a subtree.
The original depth and visit limits remain; it does not raise the budget or
return partial discovery after exhaustion. Empty-slot inspection uses its own
cache per slot so a previously visited occupied slot cannot become a false
empty-slot result. The 24-icon combined refresh now passes with every independent
icon buffer changed in both cycles, all entries retained, the panel visible, and
overflow restored to collapsed during native expansion/collapse. A capture of
the actual strip at `waitingBeforeTick3` showed all 24 updated 49-circle images
below the menu bar, at screen bounds (476, 45, 1104, 44). The installed app also
passed the native hide/reveal and overflow activation/restoration regressions.

NookBar currently restores visibility to capture the region and reapplies hiding.
This briefly reveals native icons during periodic refresh. Ice's per-window
off-screen capture cannot be claimed here: inspected CGWindow metadata did not
expose matching individual status windows on this host. Avoiding the interruption,
other displays, result-set changes, refresh cancellation/activation races, and
full lifetime identity isolation remain required parity work. Region captures
also retain the native menu bar background around icons; matching Ice's
per-window image transparency remains a capture fidelity task.

## Public single-window capture diagnostic

A developer-only `--status-window-capture-check --report /absolute/path/report.json`
now investigates public ScreenCaptureKit inventory and the owned control window.
The initial native run exposed an unchecked integer conversion in the diagnostic;
the checked conversion now rejects incompatible IDs without crashing. A repeated
run recorded AppKit `windowNumber` 4294967296, outside the public UInt32
CGWindowID range, and produced no image (`status-window-capture-v2.json`). This
does not establish that all status surfaces are unavailable: inventory must be
examined independently of AppKit's window-device number. No foreign window or
truncated ID is substituted. Normal region capture is unchanged.

The v3 native report (`status-window-capture-v3.json`) successfully inventoried
206 shareable windows before rejecting the AppKit number. Four MenuBarAgent
windows had layer 24 and full menu-bar bounds `(0, 0, 2056, 39)`; all four were
reported offscreen. These are whole-bar surfaces, not established individual icon
windows. Their presence warrants a scoped surface-capture experiment but does
not prove transparency, hidden icon content, fresh pixels, or item mapping.

The installed `--menu-bar-surfaces-check` v1 captured all four matching surfaces
successfully through public ScreenCaptureKit, without revealing items or opening
overflow. Each image measured 4112 by 78 pixels. Independent image inspection
showed surface 13139 as an opaque full menu bar, while 13802/13804/13805 had mostly
alpha 1 backgrounds with partially/fully opaque content. PNG alpha histograms
confirmed that the near-transparent backgrounds were not fully clear pixels.
The images and metadata are retained as `menu-bar-surfaces-v1.json` and its
per-surface PNGs in the local task outputs. This establishes surface capture,
not individual icon mapping or fresh hidden content. Controlled glyph changes
and surface/physical-layout correlation are required before replacing region
capture. The normal app was relaunched after the diagnostic.


## Public status-surface inventory probe

`StatusWindowCapture` is a developer-only, read-only SCShareableContent and
CGWindow metadata inventory. It queries windows with
`onScreenWindowsOnly: false` before inspecting the owned status item's AppKit
window, so an absent or nonrepresentable device number does not discard the
public surface inventory. No window titles or arbitrary foreign pixels are
captured. The result retains an optional image field for diagnostic compatibility,
but it currently always returns nil and reports `mappingVerified: false`.

The initial probe assumed `NSStatusItem.button.window.windowNumber` was a
`CGWindowID`. On macOS 27 this conversion trapped before inventory was read.
The corrected installed v2 report recorded AppKit number `4294967296`
(`0x100000000`); exact UInt32 conversion rejected it without capture. Its low
32 bits would be zero, the null CGWindowID, and are not used. Apple documents
[`NSWindow.windowNumber`](https://developer.apple.com/documentation/appkit/nswindow/windownumber)
as an AppKit window-device identifier distinct from the WindowServer global
window number. Even representable numeric equality plus process/frame matching
does not establish that a candidate SCWindow is the owned status surface.
No public mapping or encoding rule has been established here.

Ice's reference cache captures selected status-window surfaces with
`CGWindowListCreateImageFromArray`, `.boundsIgnoreFraming`, and `.bestResolution`,
then crops each surface and retries failed composite entries individually. It
merges successful captures without revealing icons or expanding overflow. Its
private CGS menu-window inventory/bounds calls and Ice2's direct shim to the
obsolete capture symbol do not establish a supported public macOS 27 path.

A future public capture experiment first needs independently verified status
surface identity. For such a proven SCWindow, the local SDK supports
`SCContentFilter(desktopIndependentWindow:)` and
`SCScreenshotManager.captureImage(contentFilter:configuration:)` with:

- Pixel dimensions derived from `filter.contentRect` and `pointPixelScale`.
- The documented default clear background and `shouldBeOpaque = false`.
- `ignoreShadowsSingleWindow = true`, `includeChildWindows = false`, and no cursor.
- Best resolution with SDR output, then explicit dimension and alpha-channel checks.

The `backgroundColor` SDK property uses Objective-C `assign`; assigning a
short-lived CGColor creates a dangling reference, so the clear default avoids
that lifetime problem. None of this configuration is currently wired into the
inventory diagnostic or normal icon capture.

Apple's [ScreenCaptureKit explanation](https://developer.apple.com/videos/play/wwdc2022/10155/)
says desktop-independent single-window capture includes ordinary windows when
occluded or offscreen. This is not proof that macOS 27 exposes individually
identifiable MenuBarAgent status surfaces. Transparent foreign icon capture,
non-revealing live refresh, and owned/foreign surface mapping remain unresolved.
