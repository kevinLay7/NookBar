# Per-icon backend investigation

Environment: macOS 27.0.1 (26A434), October 11, 2026. Independent visibility and
arrangement of multiple icons from one app remain required for full Ice parity.
The app-wide assertion backend does not satisfy that requirement.

## Wide divider experiment

Added a developer-only `--separator-lab` window to the signed NookBar app. It
creates three temporary status items, L, |, and R. Its buttons expand | to
10,000 points or contract it to 24 points. Expansion automatically contracts
after ten seconds; closing the window removes all three items. Saved user app
sections are untouched. The normal launch does not create this window or its items.

The probe uses the same basic AppKit width mechanism as Ice's control item,
including creating at zero length, an autosave name, the legacy preferred-position
preference, and clearing/disabling the divider button while expanded. It is a
controlled reproduction of that mechanism, not execution of Ice's full control
item lifecycle or its private constraints.

Observed through CUA and the app's menu-region capture:

- A 24-point divider appears between other menu bar icons.
- A request for 10,000 points increases the local AppKit status-item window
  width. One observation during its animation measured 5,016 points.
- The divider is omitted from the filtered on-screen entry list, while the
  other third-party icons remain in the menu bar image. L remains visible.
- The final image explicitly reported capture with requested width 10,000,
  after a settling delay. This avoids mistaking a previous contracted image
  for evidence of expansion.
- Closing the diagnostic removed its three items. An independent snapshot
  returned to one NookBar item and preserved all third-party app occurrences.

Conclusion: this reproduction does not hide the icons to its left on this Mac.
Replacing discovery alone is insufficient to establish a working per-icon
separator backend. It does not rule out another native mechanism.

## Intrinsic-width follow-up

A second button supplies a transparent 10,000-point image, sets image scaling to
none, and requests the AppKit variable-length mode. This separates an intrinsic
image-width request from the fixed-length setter used in the original probe.
The image uses a bounded 40,000-byte transparent bitmap representation, and
contracting removes it. The same ten-second restoration timer applies.

Observed on the signed installed app through CUA: requested length -1, image
width 10,000, and a 10,000-point local AppKit window. AX groups changed from 84 to
80 because the divider's occurrences disappeared. The captured menu region still
showed L, R, and all third-party icons; no third-party app disappeared from the
snapshot. Contracting returned to 84 groups and four NookBar status items.
Thus neither this intrinsic-width variant nor the original fixed-length variant
established a working separator hiding backend on this Mac.

## Native movement follow-up

The diagnostic now has a Swap L and R button. It accepts only its own named L/R
items, requires non-overlapping on-screen geometry, a contracted divider,
event-posting access, and released mouse buttons. It requests a bounded native
Command-drag through the app's movement code. Cancellation, close, and termination
release any pending mouse gesture immediately; foreign item identities are not
accepted. This is a developer check, not a public arrangement feature.

Verified through CUA, independent AX metadata, and settled menu-region images:

- Initial R x=1175, L x=1835. Moving L left of R produced L x=1175, R x=1215.
- The L/R order survived a signed-app relaunch. The legacy preferred-position
  keys remained 2 for L, 0 for R, and 1 for the divider, so those values do not
  describe the observed persisted native layout.
- Swapping in the other direction produced R x=1175, L x=1215. Swapping again
  returned L x=1175, R x=1215. Both captures showed the requested actual order.
- AXPosition remained non-writable throughout. A native gesture can therefore
  move these items despite the absence of writable AX geometry.

This establishes movement and relaunch persistence for these owned status items
on this display. Physical user Command-drag, foreign items, unmovable/system
items, clipped icons, general stable identity, interruption, and other displays
still need verification. It does not establish independent icon hiding.

## Accessibility constraints

A focused read of NookBar's test items found `AXPosition` non-writable. Each
MenuBarAgent group exposes the owning app's full menu-bar item list. Two of
NookBar's returned item frames overlapped, even though there were four status
items. The group frames also overlapped for those two items. This matters for
matching captured images to identities; a frame or successful query alone is
not enough to validate an arrangement operation.

This observation is limited to the test items and this display. It does not
establish that all app item frames are wrong, or that Command-drag is unavailable.

## REA findings

Read-only runtime metadata of `MBAssessmentModeConfiguration` and
`MBAssessmentModeAssertion` found `allowedSystemItems`, `allowedBundleIdentifiers`,
and their configuration/activation/invalidation methods. No per-icon allowlist
was found in these two classes. No assertion was activated by this probe.
Other classes, inherited methods, and protocol interfaces remain outside its scope.

Evidence: `ev_51536d3bc860c258761ac880333a341d37e8593f90c6b9d010135bfee76362ad`.

Static REA analysis of the installed MenuBarAgent arm64 executable
(SHA-256 `7bb3f595fa3fba81fa62518dcb5cbc0d3faf67e63885a9f3b5903184b4141007`)
found these implementation leads:

- `MenuBarOverflowComponent`, `AssignCollapsedOverflowFramesPass`,
  `ResolveOverflowGroupsPass`, and `OptimizeLeadingItemsVisibilityPass`.
- `statusItemLocations` and a legacy NSStatusItem preferred-position fallback.
- A drag-session selector taking an assertion ID, displayable ID, screen
  coordinates, item dimensions, offsets, and display ID.
- `MenuBarUtilitiesServer.ClientConnection` methods to get or clear preferred
  trailing item positions. The inspected getter is a forwarding thunk; its
  delegated behavior has not been traced.

String evidence: `ev_c07711bb5991702c92142394dbd71494aa7aab36de2195e6edbcc3cbb1544010`.
Procedure inventory: `ev_c6517eb3bb8710c478f0c5489aeb4b527c0eb4f2cb54921b679ef2cc380000b6`.
Getter analysis: `ev_b0163118774e610c1aef192b9c0dad2551e5ecaa6fe4b17ba83b8467cf307be4`.

### Architecture and forwarding-body follow-up

The universal binary contains `arm64e` and `arm64e.x1` slices. REA normalizes
both to the architecture family `arm64`; that label alone is insufficient to
select a matching slice for independent disassembly. REA read 16 bytes at
`0x10032f138`: `fea7c1dafc6fbaa9fa6701a9f85f02a9`. Those bytes match the
`arm64e.x1` slice, whose function starts with `pacibsppc`. The `arm64e` slice
has different bytes and code at that address and must not be used to interpret
this REA address.

Byte evidence: `ev_ed760f3e88b3388d57351cdd6d77a45cacdb46c464803ae10aad97407b11742f`.

REA did not recognize procedures containing `0x10032f138` or `0x1003307f4`;
requesting function analysis for the former returned no procedure. A bounded
LLVM disassembly of the matching slice establishes that the first address has
code and a function prologue. Its initial calls include Swift Logger metadata,
log-object lookup, and `os_log_type_enabled`, as resolved against the slice's
indirect-symbol table. This prefix does not establish the getter's return
contract or its authorization checks. Continue from the matching slice; do not
infer a usable API from the thunk or this logging prefix.

These static names are leads, not proof of a usable third-party API. Runtime
reachability, ownership checks, entitlements, identity mapping, and persistence
are unresolved. No drag-session or utilities request was sent to MenuBarAgent.

## Utility and item-manager interface follow-up

Read-only Objective-C runtime metadata from the installed MenuBarClientCore
framework exposes MBMenuBarItemManager, item IDs/content/tags, and layout callback
methods. Its utility protocol includes getPreferredTrailingItemPositions and
listMenuBarItemsForSpaceID:completionHandler:. This expands the earlier two-class
assessment probe; the native item manager's ownership boundary is still unknown.

Protocol evidence: `ev_cb3600d5eec0eb98cd56da4052f76ad9b116401daad7fd76ae14b53349c3da7f`.
Class metadata evidence: `ev_958ff387329c453527811805e2f1c1906d14871ba4c81466371c5b01d038a37d`.

The framework is present in the dyld shared cache rather than as a standalone
Mach-O file. Apple's dyld_info found its exports and decoded the service-definition
getters; a controlled probe of the installed getters returned:

- Service: com.apple.MenuBarAgent.utilities
- Required entitlement name: com.apple.private.menubar.utilities

Getter evidence: `ev_dd4d44eda57ae0bfc16c2366d90eca31fdcf27c428b6ec72b659c459202f1c5f`.

A separate read-only helper used a reconstructed Swift interface matching the
exported initializer and final async method symbols. The installed framework was
loaded into this helper at launch. Its ping request returned sessionNotActive;
subsequent position/list requests were skipped after that error. MenuBarAgent's
log at 2026-10-11 15:22:40 reported the same helper PID missing the private
utilities entitlement. No mutation method, private entitlement grant, or change
to system protections was attempted.

Request evidence: `ev_5847af4eab50e198360fa9e7505f836556a6b839b49a1bfafdf62a0b08313de8`.
The request and correlated denial rule out this utility connection for that
unentitled probe. They do not prove the authorization rules of the item manager
or other service interfaces. Do not build the public app around this rejected
utility route or represent it as an Accessibility permission the user can enable.

## Next checks

1. Extend the verified native gesture path to a general arrangement operation
   with validated identity, ownership, restoration, and interruption handling.
   Trace overflow visibility contracts without relying on the rejected utility service.
2. Validate foreign and physical Command-drag, including saved item identity/position.
3. Match actual rendered icons to stable identities across rearrangement and
   relaunch, including several icons from one app.
4. Implement and verify independent native hiding and ordering, restoration,
   system extras, clipped icons, Spaces, and each display. Keep app-wide behavior
   labeled as partial until these requirements are met.

## Public ordering follow-up

The Arrange Icons window now uses live AX references to match source and target
items, confirms their identities with a system-wide hit test, posts a bounded
Command-drag, and verifies adjacency in a fresh query. Stats’ CPU icon moved to
both sides of its RAM icon through the public controls. The moved order survived
NookBar relaunch; Stats was not restarted. This establishes a foreign-item ordering
path for that pair on the built-in display. It does not establish system-item
movement, persistent identity across target-app restarts, physical row dragging,
or independent item visibility. Closing the window reapplies the requested
app-wide hidden state without changing saved section assignments.

## Captured item identity limits

Strip activation now retains the original AX entry and checks live identity,
process launch date, and description. It no longer selects the nth item from an
app, which could open another item after ordering changes. A fresh entry must
match uniquely on the chosen display. Captures also reject changed positions
between discovery and screenshot completion.

A controlled native diagnostic created an item, removed it, and then created
another with the same label. Removal made the old entry unresolvable, but the
same-label replacement reused its AX identity. `CFEqual` therefore cannot prove
item lifetime isolation within one process. The explicit report flags
`sameLabelReplacementRejected` and `identityIsolationProven` remain false; no
unique persistent identifier or replacement-proof item membership is claimed.

A read-only AXObserver probe on NookBar and all three Stats items returned -25207
(`kAXErrorNotificationUnsupported`) for destroyed, layout-changed, and created
subscriptions. Apple documents this return value for unsupported observations
([AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)).
This runtime provides no tested notification path for that invalidation. Further
research is required; polling cannot prove that a remove/recreate cycle did not
occur entirely between reads.

## Native overflow capture reproduction

October 11, 2026, macOS 27.0.1 (26A434), built-in display. The developer-only
`--overflow-probe` creates 24 numbered NookBar status items without saved positions.
Normal launch creates none. With the app-wide assertion released, independent
AX traversal returned S4 through S24 at the same positive frame:
`(1151, 7.5, 33.5, 24)`. Every center hit test resolved to MenuBarAgent's
`AXButton` labeled `Show Hidden Menu Bar Items`, not the original icon. A settled
menu-region image showed the overflow chevron and S1/S2/S3, with none of S4–S24.
The three visible entries hit their original AX identities.

NookBar's existing bundle-and-frame deduplication collapses those 21 entries
into one representative. It is therefore unsuitable as a complete overflow
inventory; a successful positive frame query cannot prove visible pixels.

Capture now requires each entry's unchanged live frame and matching center hit
test both before capture and after the screenshot returns. Native activation
uses the same exposure check after identity resolution. An obscured capture
fails explicitly, leaving apps revealed, rather than caching another control's
pixels or silently omitting requested icons. Same-label replacement identity
and brief changes entirely between samples remain unresolved.

The installed signed app's `--overflow-probe --overflow-check --report PATH`
performs a read/capture-only regression on its own disposable icons. The live
report returned one collapsed representative, three exposed entries,
`collapsedCaptureRejected: true`, `visibleCaptureCount: 3`, and `passed: true`.
It does not press an icon or establish automatic overflow expansion. That path,
and a complete inventory retaining separate collapsed identities, remain needed
for full hidden-strip parity.

REA/Hopper also traced `AssignCollapsedOverflowFramesPass`'s string at
`0x1003605d0` to Swift type metadata at `0x10038a898`. Its code reference at
`0x10022cfc0` belongs to the metadata accessor `sub_10022cfbc`, which calls
`swift_getGenericMetadata`; this is not the layout pass body or a callable
third-party visibility API. Evidence:
`ev_8f4e9b92392b68e13aa18b48a1afb656ec98b19e8aaafb71b870e2ead101f43c`,
`ev_ff501c483015e8893c1a41524651928f32299067ea23c3408d030a5d14004226`,
`ev_48a1e084885300db23a20ccc544ea67b630380a8da93ad46640f3a7c68b90f70`.
The overview's document name ends in `arm64e.hop`, but byte reads at the overflow
string and `0x10032f138` match the selected `arm64e.x1` slice, not `arm64e`.
Binding evidence:
`ev_da218dc275dffb4882cfc61fcbc17f4fae66f1989ebbb1984c3c24c12cad530e`,
`ev_84167acf7abc24c525e1f68aaccccfdf2af3669c0290a190f7829511ce0a9b31`.

### Automatic expansion, inventory, and activation follow-up

The exposed overflow button advertises an empty AX action list. A background
CUA press changed one inactive Accessibility copy to `Hide Menu Bar Items`,
while the on-screen center hit still returned `Show Hidden Menu Bar Items` and
the physical image remained collapsed. The native implementation now reads the
localized show/hide labels from MenuBarAgent's `MenuBarCore` bundle table and
selects the control using its actual system-wide hit identity and owning PID.
It posts a bounded left down/up pair only with existing event-posting access
and no held mouse buttons, then restores the pointer position. Delivery does
not prove expansion; callers poll the live state and item exposure.

Physical expansion exposed S24 through S4 to the left of the notch. Independent
hit tests then returned each original NookBar item identity at its actual frame;
S24 was at `(187, 7.5, 33.5, 24)`. Some MenuBarAgent group copies retained the
collapsed region. Discovery now keeps separate AX identities at shared frames
and accepts exposed `AXMenuExtra` items outside stale group regions only after
a matching live hit test. It no longer drops 20 of the 21 collapsed probe icons.

The normal capture path owns a temporary overflow lease only if it opens a
collapsed bar. It waits up to two seconds for every requested identity to be
exposed, captures with the existing before/after checks, and verifies collapse
before returning images. An already-expanded bar is preserved. Cancellation,
capture failure, Show All, hiding, and app termination request restoration of
NookBar's lease. Icon activation can acquire the same lease, expose the retained
identity, and press it; the existing menu-close watcher restores it before
rehiding. Overlapping captures cannot take the same lease.

The signed installed app's expanded diagnostic now verifies all 24 identities,
24 captured images, automatic capture/restoration, already-expanded state
preservation, and activation of S24's actual native button action. An optional
`--overflow-strip-preview` displays those captured images for 15 seconds. A
physical screenshot showed the complete numbered 24-to-1 strip below a collapsed
menu bar. These checks cover owned icons on the built-in display. Foreign
overflow menus/popovers, system extras, other displays/Spaces, interruption,
permission loss, and same-label replacement isolation remain unverified.

### Discovery and changing-description regression checks

A broad hide/reveal regression exposed four separate AX identities for each
MenuBarAgent-hosted system extra at an identical visible frame. Independent
queries found exactly one exposed identity for each of Focus, Battery, Control
Center, and Clock; the other three copies failed the center hit test. Discovery
now discards those inactive copies only when an exposed copy proves the current
pixels at the same frame and label. Unknown collapsed identities remain in the
inventory. A read-only query reduced 30 entries to 18, retaining the exposed
system extras and the distinct third-party items. Some system agents have no
launch date: same-query deduplication uses raw AX identity, while later activation
still requires the original launch-date evidence. System activation remains pending.

The same regression found Macs Fan Control's description changing with live RPM.
Its AX/process identity survived hiding and restoration, but exact-description
resolution rejected the older capture. The diagnostic now reports identity
restoration separately from `liveEntriesResolvable` and
`descriptionChangedBundles`; the latter named Macs Fan Control in this run.
It no longer assumes that frames are unique. The signed app's hide/reveal,
discovery, capture, foreign hiding/restoration, and removal/rename checks passed;
`liveEntriesResolvable` remained false and same-label replacement isolation
remained unproven. Dynamic descriptions still require refreshed captures; this
follow-up does not relax the activation guard or claim dynamic refresh is solved.
