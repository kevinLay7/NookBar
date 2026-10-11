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

## Next checks

1. Trace native overflow locations and drag-session contracts, including their
   ownership and permission checks, before attempting to use them.
2. Validate a physical Command-drag and its saved item identity/position.
3. Match actual rendered icons to stable identities across rearrangement and
   relaunch, including several icons from one app.
4. Implement and verify independent native hiding and ordering, restoration,
   system extras, clipped icons, Spaces, and each display. Keep app-wide behavior
   labeled as partial until these requirements are met.
