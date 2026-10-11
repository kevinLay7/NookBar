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
