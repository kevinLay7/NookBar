# Icon search

Ice's pinned Ifrit 2.0.6 reference at
`3f961f6d39cd2188305671f2ec65914d297571d0` filters candidates with Fuse's
0.5 threshold, then averages result rank with its boundary/camel-case
`bestMatch` alignment score. NookBar now implements that scoring in
`IconSearch.swift`, preserving original-index ties and the existing keyboard
and refresh selection handling in `HiddenBar.swift`.

An isolated differential harness compared 4,050 scores and 25 full rankings
against the pinned reference, with zero mismatches. It included Unicode,
typos, word boundaries, camel case, randomized inputs, and 36–64-character
patterns. Integrated behavior checks also cover combined app/icon queries,
bundle search, accents, empty-query order, and long-pattern handling.

NookBar intentionally searches the combined app/icon title plus the bundle
identifier, preserves accent folding, and uses a safe edit-distance extension
for patterns longer than 64 characters. Those additions are not claimed as
bit-for-bit reference behavior. Dependency notices and licenses are preserved
in `LICENSES/IconSearch.txt`.

The combined build and behavior checks passed. In the installed search window,
`Stats CPU` ranked CPU before Disk/RAM, and `Stas CPU` retained CPU first.
An earlier keyboard activation attempt was inconclusive because observing
NookBar afterward reopened its strip. The repeated test below avoids that
interference. Changing-result selection checks remain required before full
search parity is verified.

The repeated installed test used `--search --interaction-report` and searched
`Stats CPU`. CPU ranked first. Return produced `beforePress`, a successful
`pressReturned`, and `interfaceCaptured` for a newly opened Stats window 4240.
Inspecting Stats directly, without observing or reopening NookBar, showed its
actual CPU window with usage history, load, processes, and frequency controls.
Escape and Command-W did not dismiss the CPU interface; cleanup is being
verified separately. Evidence is retained locally in
`outputs/search-activation-v2.ndjson`. This verifies ranked Return activation
for CPU; result-set changes, other apps, always-hidden/system coverage, and
seamless refresh remain separate checks.

The same trace subsequently recorded `interfaceClosed` with `pending: false`,
then successful `hidingCompleted`. That proves the tracked CPU interface closed
and the ordinary app-hiding backend resumed; the earlier dismissal attempts
should not be counted as successful actions.
