# Per-icon backend investigation

## Persistent membership foundation

`AppSections` now stores per-icon section overrides in `IconSections`, including
explicit Visible overrides of an app's Hidden assignment. Removing an override
restores the app fallback; clearing assignments clears overrides as well. The
native bridge supplies a JSON tuple key of bundle, primary descriptor kind, and
primary descriptor value, rejecting empty descriptors. This avoids ordinal and
delimiter-based keys but does not prove stable lifetime, unique membership, or
stability of changing labels. Assignments now also store owner bundle/PID/launch
date evidence in `IconSectionProcesses` and require a unique live inventory
match. Choices survive a NookBar reload in the same owner process; an owner-app
restart requires deliberate reassignment. Missing, changed, duplicate, or stale
choices stay visible until confirmed. Unassigned siblings inherit the app
setting only when all saved same-app choices resolve. No movement/capture
identity guards are relaxed. Behavior checks cover these storage cases.

The arrangement picker and application flow are connected in the working tree,
but native production-backend validation remains incomplete. The v4 diagnostic
failed at divider positioning and order recovery after moving Disk into a
selective partition. Icons were restored to exposure but original order was
not proven restored by that run; repair and rollback validation are required.
Do not treat the earlier adjacent-divider success as proof of arbitrary
membership arrangement. Same-label replacement lifetime isolation and automatic
rebinding after target-app restart remain unresolved. No real user section
assignments were migrated or changed during these diagnostics.

Installed arrangement validation found Stats' three labels came from AXHelp,
so the original primary-descriptor-only preference keys disabled their section
controls. Preference keys now support captured AXHelp only when primary fields
are absent; a direct fresh AX field/kind comparison rejects changed keys before
assignment or effective membership. These are exact process-bound choices, not
a claim that tooltips are stable identifiers. Capture/activation/movement retain
their separate original descriptor checks.

The same UI check found one failed whole-inventory capture erased all row images
and incorrectly suggested missing Screen Recording permission. Arrangement
capture now retains successful images by original row index, reports individual
errors and counts, and suggests permission access only when its preflight check
actually fails. Unsupported system captures remain a parity requirement.

The foreign-order repair after v4 was independently verified with live labels
and a menu-region image. Rollback now tracks only moved foreign items, and the
application waits for applying/recovery work to become idle before reapplying.
Native validation of the updated arbitrary-partition backend remains required.

The next installed UI run initially timed out. A live process sample showed
capture AX reads re-entering AppKit table drawing, whose section pickers then
performed further synchronous live AX reads. Table rendering and selection
now use captured snapshot matching; strict live checks remain at assignment
and backend boundaries. After a fresh successful build, the installed window
responded promptly, loaded 13 of 18 images, reported five captures unavailable
for missing process identity, and enabled the Stats section selectors. Choosing
CPU Visible wrote `["eu.exelban.Stats","help","CPU: Mini"] = visible`;
choosing Use App Setting removed that override and restored the displayed
fallback. Temporary test choices were removed before closing. This verifies
UI assignment/storage and partial capture, not native per-icon hiding or
automatic persistence across owner-app restarts.

Read-only kernel process-start checks subsequently verified full public
`proc_pidinfo(PROC_PIDTBSDINFO)` records for SystemUIServer, Control Center,
MenuBarAgent, and Stats; invalid/missing PIDs were rejected. Entries with a nil
AppKit launch date can now capture an explicit kernel-start key, which is
independently revalidated during identity comparison. Existing launch-date
keys retain their format. This supplies owner-process lifetime evidence without
claiming status-item lifetime isolation. System capture still requires native
GUI verification, and system drag sources remain explicitly unsupported.

The v6 native backend run exposed the requested target through native overflow,
but dragging the divider to that expanded target collapsed overflow and did not
establish the intended placement. The run verified restored foreign order and
exposure after failure. The next algorithm places the divider at an already
exposed boundary before moving preceding visible foreign icons to its right;
its own control observation is bound to retained status-item objects. These
changes are pending native verification, rather than a passing arbitrary
partition result.

The direct v10 test passed the reusable backend on Stats Disk: width 48,
active/validated true, one exact Disk image captured through native overflow,
collapsed-state restoration, retained real NookBar control, and restored foreign
order/exposure and system regions. Independent review of before/hidden/restored
menu-region images found the narrow blue Disk icon absent while hidden and
present again afterward, with CPU/RAM visible. This verifies this concrete
partition on the built-in display, not all app/display/lifecycle combinations.
Saved public assignments and mixed legacy app selections remain the next
integration checks; app-default hiding must not demand a per-icon key from
otherwise unidentifiable icons, nor relax matching for mixed per-icon choices.

## Foreign same-app divider follow-up (October 11)

A subsequent diagnostic adds a second disposable item, V, moves it to the
visible side beside CPU, and requires V to remain hit-tested/exposed during
every width step. That run selected 384 points, independently hid Disk, captured
one Disk image, preserved V, and restored foreign order/exposure and system
regions; `visibleControlPreserved` and `passed` were true. Both disposable items
were removed. This verifies placement of an owned visible control without
changing the saved position of NookBar's real control. It does not yet prove
normal control interaction or lifecycle recovery with this backend.

The developer-only `--foreign-divider-check --report PATH` creates one disposable
NookBar divider and moves only that divider between adjacent exposed Stats
icons. No foreign icon is dragged and no section assignment, saved divider
position, or user preference is written. Optional `--divider-capture-dir PATH`
saves menu-region images before expansion, while hidden, and after removal.

On this built-in display the chosen pair was Stats' Disk and CPU icons. The
probe increases divider width in 24-point steps, bounded at 600 points. At 432
points it observed Disk unexposed and CPU exposed, with every protected foreign
icon to the right still exposed and the native overflow control collapsed.
The physical image shows Disk and the leading icons absent while CPU, RAM,
and the system extras to the right remain visible. Native overflow expansion
captured one actual Disk image and restored collapsed overflow. Removing the
divider restored the original foreign AX/process identities in their original
order and exposure, with initial/final overflow both -1 (no exposed overflow
control). The restored physical image shows the original icons again. The
before/after preference domains were identical.

The final report returned `independentForeignHideObserved`,
`captureRestoredCollapsed`, `foreignOrderRestored`, `foreignExposureRestored`,
`systemRegionsRestored`, `foreignPairCheckPassed`, and `passed` true;
`hiddenForeignCaptureCount` was 1. This is the first verified independent hiding
of two icons from a foreign app through a divider on this host. It does not
establish public per-icon membership or a production backend.

Restoration checks AX/process identity and exposure separately from primary
descriptor resolution: an original temperature label changed from `69°C`, so
`foreignDescriptorsResolvable` was false and `changedDescriptorLabels` recorded
that entry. Capture/activation descriptor guards were not relaxed. Same-label
replacement lifetime isolation remains unproven.

The Clock intermittently failed AX exposure observations even while visible in
the menu-region images. The diagnostic records all protected-item failures,
but only a foreign item with a validated process identity stops the bounded
width scan. System extras lacking launch dates are checked as read-only labeled
regions using live center hit tests, independently of the foreign pair check;
the broader `passed` flag also requires their final region restoration. These
region observations do not authorize system-item capture/movement or establish
stable system identity. The final chosen-width observation had no protected
failures, but uninterrupted preservation across every intermediate width is
not established by this run.

Application menus changed during testing. A 432-point result is not a universal
constant or a verified width-selection policy. Remaining work includes adapting
to changing menu widths and notch/display constraints, preserving NookBar's
control on the visible side, persistent per-icon sections, selective reveal,
interruption/recovery, and verification across system items, displays, Spaces,
and lifecycle events. The public app still uses app-wide hiding.

## Moderate-width follow-up (October 11)

The earlier 10,000-point experiment does not rule out a divider at ordinary
widths. A new developer-only `--width-check --report PATH` creates temporary
R/D/L items without assigning saved positions, changes D through 24, 100, 200,
400, 600, 800, then 24 points, and records live AX exposure. Optional
`--width-capture-dir PATH` captures the menu bar at every stage for pixel checks.
The normal app does not create these items or change their widths.

On the built-in display with Hopper's application menus active:

| Requested D width | Physical/exposure result |
| --- | --- |
| 24 | L, D, and R visible/exposed |
| 100 | All three exposed; D's exposed width 102 points |
| 200, 400, 600 | L and D absent in the actual menu image; R remains exposed |
| 800 | Only R remains; no exposed overflow control is found |
| Restored 24 | All three visible/exposed again; overflow collapsed |

The follow-up holds D at 200 and exercises the existing overflow path. It
observed L unexposed and R exposed, captured one real L image after automatic
expansion, restored collapsed overflow, delivered a native click to L, and
observed L's handler tag 101. Contracting D restored all three owned items.
Initial and final overflow states were both 0. No app-section assignment or
foreign icon order was changed.

This is evidence of independent owned-item hiding through layout, not a public
per-icon backend. Foreign-item movement/membership, different application-menu
widths, displays/Spaces, width selection, visible-item preservation, and recovery
remain required. The inaccessible overflow control at width 800 is a concrete
reason not to adopt a fixed oversized width. Public hiding still uses the
app-wide assessment backend.

The macOS 27 SDK's `NSStatusItem.h` exposes ownership-local `visible` and the new
expanded-interface delegate/session API, but no overflow pinning property in
that header. `NSStatusItemExpandedInterfaceSession.h` exposes cancellation,
without a cross-app visibility operation. These header observations do not
establish that no other platform contract exists.

REA/Hopper inspected MenuBarAgent SHA-256
`7bb3f595fa3fba81fa62518dcb5cbc0d3faf67e63885a9f3b5903184b4141007`.
The overview counted 14,762 procedures and 7,811 defined strings
(`ev_3cb3e32350533874a28d4b072cfb351a64365e0ba4c95e84cd492ea98e5c280c`).
Literal `pinned` string search and `overflow` procedure-name search returned no
matches within those provider inventories; neither proves an API is absent
(`ev_559fee5e8971ba29b0eefdccf54822f9febb2a52c12f2f5153d104183f4a5a37`,
`ev_938dcb6ed2cc84568868bd9268c5dee8a18a483d059aac12918aae45aac49de0`).
The `visibility` search found `OptimizeLeadingItemsVisibilityPass` at
`0x1003607d0`; its returned xref points to data at `0x10038aa90`, not an established
callable visibility implementation. Evidence:
`ev_18b5de30769c4ce7695f39336e1db50b61a6aa14d52e69b5f1cfadbcbbf9021d`,
`ev_763bfd5e64fe35eb9737865382d2e4051be5288b1df7f8ebb656524d345e8b37`.

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

## Persistent physical sections proposal (source research, October 11)

Legacy Ice's independent sections are defined by physical item positions around
persistent owned controls, rather than by a database that reidentifies each
foreign item after its process restarts. In the local `Ice2-reference` source,
`MenuBarItemManager.swift:319–334` classifies an item's current bounds as Visible
when right of the Hidden control, Hidden when between the Hidden and Always
Hidden controls, and Always Hidden when left of the Always Hidden control.
`ControlItem.swift:79–84` creates each control with a stable `autosaveName` equal
to its identifier. Its comments at lines 87–93 explicitly explain that the
controls must remain present because their positions define section membership.

That source also preserves a control's `NSStatusItem Preferred Position` value
around removal (`ControlItem.swift:110–115` and `453–456`). Its preflight setup at
lines 687–708 seeds preferred position and visibility defaults only when absent.
These are source observations, not proof that macOS 27 honors those legacy keys
in every layout. Earlier NookBar movement checks showed native L/R order
persisting while the legacy preferred-position numbers did not reflect that
order. Actual restored control and icon geometry must remain the acceptance
criterion; writing or reading a preference is insufficient.

Ice's semantic tag is namespace plus CGWindow title
(`MenuBarItem.swift:325–337`). The namespace prefers a source app's bundle ID
at lines 374–376, or owner bundle/process name at lines 358–362 and 392–397.
The unknown-owner fallback caches a UUID by CGWindowID in memory at lines 344
and 400–406, so it supplies no restart-stable identity. Public window metadata
includes `kCGWindowName` and owner PID (`WindowInfo.swift:50–60`), but this older
item inventory also calls the bridging window-list/geometry path. A unique AX
item to CGWindow mapping on macOS 27 has not been established. The macOS 27
native fork maps ordinary items to `bundle:<bundle>`
(`NativeMenuBarPolicy.swift:50–60`), which also does not solve independent
same-app persistent identity. The rejected entitled utilities connection is
not a usable way to acquire stronger item identifiers.

A scoped implementation should therefore preserve physical sections directly:

1. Keep two named owned boundary items present while their sections are enabled,
   with fixed distinct autosave names and a contracted, discoverable width.
   Retain NookBar's existing control on the visible side. Initialize default
   positions only for a genuinely new configuration. Never rewrite saved
   positions on every launch or remove/recreate controls on each hide/reveal.
   Preserve owned control preference values when intentional teardown requires
   removal, and verify restoration from live geometry after startup settles.
2. Derive membership from a fresh contracted inventory and the two live boundary
   frames. Require uniquely resolved, exposed item identities and correct
   boundary order; crossing or overlapping frames are unresolved. Dynamic labels
   are display text, not saved item IDs. Once layout is established, hide and
   reveal by changing the appropriate boundary widths without repartitioning or
   moving foreign icons on every refresh. Keep the bounded width/protected-item,
   recovery, and ownership guards already being verified by the divider backend.
3. Moving an icon to another section performs one validated native movement
   across the appropriate boundary and verifies its resulting physical region.
   Moving an app's current icons is an explicit group operation, rather than a
   continuing app assertion that can override later individual placement.
   Temporary single-icon reveal records and restores its native return position
   with the current identity guard; it does not persist a runtime identity.
4. Treat existing app assignments as a one-time migration plan for the currently
   resolved live inventory. Apply current valid per-icon choices over those app
   defaults, then establish the resulting physical partition using native
   moves. Keep the old preferences available until every planned move and the
   boundary layout have been verified. Missing apps, duplicate identities,
   stale process-bound overrides, or failed restoration leave migration pending
   and the affected items visible. Mark migration complete only after the
   contracted layout proves the requested regions; thereafter the physical
   boundaries govern membership, and legacy defaults must not continuously
   move user-arranged icons back. A later explicit app assignment expands to a
   fresh live group operation. Do not infer completion merely from launching
   NookBar or successfully writing an autosave preference.

This design avoids matching a newly created runtime item against an old dynamic
label. It does not guarantee that every foreign app saves its own status-item
position: an app that recreates or repositions its icons may change their
physical section. Verify, separately, NookBar relaunch, independent Stats
relaunch, changing Stats display styles/help, one icon disappearing/reappearing,
boundary removal/recreation, and display/Space transitions. The desired evidence
is each actual icon's physical region, not equal labels or equal AX references.
Use controlled fixtures for duplicates and items with no primary descriptor.
Stats' current `CPU: Mini`, `Disk: Bar chart`, and `RAM: Mini` values were observed
only as AXHelp. Their exact process-bound choices remain useful for initial
explicit arrangement but are not promoted to restart-stable IDs.

No persistent-boundary implementation or target-app restart experiment was
performed by this source-research addition. Same-process remove/recreate AX
identity reuse remains an unresolved item-lifetime limit.

## Saved public assignment with legacy app defaults (October 11)

On the signed installed app, the public Arrange Icons picker assigned Stats'
`Disk: Bar chart` to Hidden. Closing that window applied the saved choice along
with the seven existing app-wide Hidden defaults: BetterDisplay, Macs Fan
Control, Jump Desktop Connect, Wispr Flow, Chrome, Tailscale, and ChatGPT.

The interaction trace recorded `hidingCompleted`, `dividerActive: true`, width
312, `dividerBusy: false`, and `dividerStage: active`. An independent desktop
snapshot showed the native overflow chevron collapsed and the seven app icons
plus Disk absent from the rendered bar. NookBar's real tray, Xcode, TaskWise,
Stats CPU and RAM, and the system extras remained visible. The hidden entries'
AX centers clustered at x1160–1181 under the overflow control at x1186; CPU and
RAM stayed separately located at x1661 and x1708.

Evidence is retained under the local task's `outputs/` directory as
`public-sections-interactions.ndjson`, `public-sections-visible.png`, and
`public-sections-visible.txt`; `public-sections-before.plist` records the original
defaults without per-icon choices. The initially missing trace appeared after
hiding completed. A NookBar CUA accessibility read timed out, while the independent
desktop snapshot returned in about one second; these observations do not
establish a permanently hung application. Test-choice cleanup was handed back
to the primary agent after that timeout, without overwriting the app defaults.

This verifies one saved public Hidden assignment combined with existing app
defaults on the built-in display. Always Hidden, selective activation/reveal,
persistent physical boundaries, target-app restarts, other displays and general
interruption recovery remain separate requirements.

The primary agent then relaunched Arrange Icons and selected Use App Setting
(Visible) for Disk through its actual popup. The `IconSections` and
`IconSectionProcesses` keys were removed. Comparing exported defaults with the
pre-test plist confirmed exact restoration of both per-icon keys, `HiddenApps`,
and `AlwaysHiddenApps`. The combined build, signature, diagnostic, and behavior
checks passed after the display-context fix was corrected for Swift concurrency.

The subsequent `--persistent-boundaries-check --initialize-boundaries` v2 test
failed to place the new Hidden marker before the automatically selected Clock
anchor. Both cycles reported rejected movement, removed the new markers, and
independently confirmed foreign identity/order/exposure and native overflow
restoration. The pre-move observation had overflow expanded, Hidden at x865,
Always Hidden at x825, and Clock at x1958.5. This narrows the next placement test
to its anchor/overflow transition; it does not prove a general drag restriction.
Evidence: local `outputs/persistent-boundaries-v2.json`. Normal NookBar was
relaunched after testing; persistent section initialization remains unverified.

The v3 repeat used the explicit `--boundary-anchor TaskWise` diagnostic option.
The first cycle moved Hidden and Always Hidden successfully, producing exposed
ordered markers at x1571 and x1531. The second cycle reported only `restored
valid contracted markers`, with identical positions and no additional drag.
Both cycles independently passed foreign order/exposure/overflow restoration
after marker removal. This verifies initial placement and recreation for that
anchor on the built-in display. It does not establish normal migration, hiding
widths, independent target-app restart persistence, or safe section treatment
of system/NookBar controls. Evidence: `outputs/persistent-boundaries-v3.json`.
