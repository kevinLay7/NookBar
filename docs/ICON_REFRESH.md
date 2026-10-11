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
changes their images twice, updates the actual panel, and compares image data.
Combine it with `--overflow-probe` to exercise overflow capture while the panel
is open. This combined check currently fails: the initial 24-icon capture succeeds,
but after showing the panel and changing images, discovery finds zero owned
probe entries and no exposed overflow control (`-1`). It does not establish
overflow refresh parity. This diagnostic does not exercise the application's three-second timer;
the ordinary strip/search observations above exercise that path.

NookBar currently restores visibility to capture the region and reapplies hiding.
This briefly reveals native icons during periodic refresh. Ice's per-window
off-screen capture cannot be claimed here: inspected CGWindow metadata did not
expose matching individual status windows on this host. Avoiding the interruption,
other displays, result-set changes, refresh cancellation/activation races, and
full lifetime identity isolation remain required parity work.
