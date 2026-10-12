# Ice feature parity

Goal: fully replicate Ice's behavior in NookBar. Publishing the repository and
passing build checks do not satisfy this goal. Every feature needs real behavior
checks on macOS 27, including combinations with other settings.

Reference: Ice 0.11.13-dev.2, source tag commit `da2dd23`, and the installed build
used in `ice-investigation.txt`. Feature requirements come from its General,
Advanced, Hotkeys, Layout, and Appearance settings, event handling, search, and
bar implementation. Static source establishes intended behavior; it does not
prove the installed Ice build works on this macOS version.

| Capability | Current implementation | Evidence still required |
| --- | --- | --- |
| Hide/reveal selected items | Default app-wide backend; direct reusable backend hides/captures Stats Disk while preserving CPU/RAM/real control and restores foreign order/exposure; public saved Disk Hidden choice also hides with seven legacy app defaults at width 312, independently verified in menu-bar pixels and AX positions | Other arbitrary partitions, selective reveal, adaptive layout/lifecycle recovery, system items and each display |
| Hidden icon strip | Actual captured icons, separate buttons; live exposure checks; distinct collapsed identities; automatic native overflow capture/restoration and activation verified with 24 owned test icons; fresh reopen and three-second idle image refresh; changing overflow images verified across all 24 owned probes with panel retention and collapsed-state restoration | Foreign overflow items and their menus/popovers; system extras; other displays; transparent icon capture; eliminating native reveal during refresh; refresh/activation cancellation races; same-label replacement identity reuse; clipped/notch items; all click variants |
| Native menu bar reveal instead of strip | Both sections' reveal/toggle behavior verified through app controls and independent AX snapshots | Physical tray click and each automatic rehide strategy |
| Control icon | Native tray plus N fallback | All displays, fullscreen, automatic menu bar hiding, custom/show/hide icon options |
| Empty-space click and secondary context menu | Global and local event handling | Physical toggle and context-menu checks, modifier combinations |
| Hover and scroll activation | Configurable hover delay; directional scroll | Physical pointer/scroll checks, debounce, fullscreen sliding menu bar |
| Automatic rehide | Smart, timed, focused-app strategies | Real menu-close and focused-app checks, pointer leave/re-entry, disabled rehide |
| Bar position | Dynamic, pointer, icon settings; vertical position constrained below menu bar/safe area even with a startup placeholder anchor | Each display, desktop edges, fullscreen |
| Temporary icon/interface reveal | App-wide reveal; exact-entry native click; configurable 0–60-second minimum (default 15), 3-second interface retry and 1-second input retry; first-new-window tracking; owned layer-0 lifetime/existing-window exclusion and real fan-menu activation/cancellation verified | Independent per-icon reveal; physical zero/max-interval and active-input combinations; simultaneous interfaces; other app/window types; restarts and multiple instances |
| Global shortcuts | Native registration and recorder; hidden/always-hidden/search/bar-mode actions | Cross-app execution, conflicts, key-up repeats; remaining app-menu action |
| Icon search | Fuse/bestMatch scoring matches pinned Ice reference in 4,050 differential scores and 25 rankings; installed Stats CPU and typo queries rank CPU first; previous native CPU/fan activation and fresh capture/refresh verified | Fuzzy-result keyboard activation without observation interference, changing-result selection/scroll preservation, other apps, always-hidden/system coverage and seamless refresh |
| Visible, hidden, always-hidden sections | Persistent app assignments; process-bound per-icon overrides; installed CPU assignment/reset and partial row captures; public Disk Hidden assignment combined with seven legacy app defaults verified on the built-in display; stale/ambiguous choices remain visible | Always Hidden and selective reveal, persistent physical boundaries, owner-app restart persistence without reassignment, physical Option activation, unsupported/duplicate identifiers and system items |
| Drag layout and ordering | Public Arrange Icons window; button movement of Stats CPU/RAM verified in both directions, with NookBar relaunch persistence and close/re-hide checks; user verified physical CPU/RAM row dragging | Other physical row pairs; drag between sections; identity across target-app restarts; system items; each display; Command-drag reveal-all behavior |
| Launch at login | Native Service Management option | Registration status and actual login; approval-required/error states |
| Startup visibility | Saved hide-on-launch option | Signed installed-app relaunch and startup permission failure |
| App launches/exits, sleep, lock, Spaces | Restore/resume and running-app reconciliation; per-icon applies serialize recovery; quit during applying waits for bounded cleanup | Native interrupted-apply/quit tests, real sleep/lock/Spaces, multiple displays and recovery after each failure |
| Menu bar spacing | Native host-specific spacing/padding settings, −16…+16 offset, defaults reset, prior-value restoration, and selective graceful app relaunch; visible owned icons verified at default, −8, −16, and +16; relaunch success/refusal and cancellation tested | Full third-party/system-icon coverage, other displays, logout behavior, launch failures, and custom pre-existing value GUI restoration |
| Menu bar appearance | Native Appearance settings and renderer: full/split shapes, independent caps, notch inset, shadow, border, solid/gradient tint, and separate light/dark profiles; actual full/split rendering and held-preview restoration verified on built-in display | Other displays, Spaces/fullscreen, automatic theme changes, moving wallpapers, permission revocation, auto-hide resume, and combinations with fallback control/hiding |
| Hide application menus when more room is needed | Missing | Native behavior, Dock visibility and restoration |
| Permissions and diagnostics | Accessibility and capture prompts | Revocation, stable signing, actionable errors and no stuck invisible control |
| Updates and distribution | Public GPL source; local signed app | GitHub downloads, signing/notarization, update checks and installation |

### Display context during strip activation

The strip now retains its capture display before closing and passes it through
both mouse and Return selection. Activation, section hiding, native pressing,
refresh, and menu-close rehide use that display rather than the control icon's
display. Detached displays are rejected before independent activation. This
fix is source-checked; actual secondary-display behavior remains unverified.

## Verification rules

See [per-icon research](PER_ICON_RESEARCH.md) for the wide-divider experiment,
Accessibility limitations, and native overflow/drag leads. See also the
[application-menu investigation](APPLICATION_MENUS_RESEARCH.md), whose tested
activation variants did not establish menu bar ownership. The early divider
experiment failed; the later reusable backend has passed the specific Stats Disk
partition described above. The saved public Disk Hidden assignment with seven
legacy app defaults has also passed on the built-in display. Neither result
establishes all partitions, Always Hidden, persistence across restarts, or other
displays.

- Build/logic checks cover only the branches they exercise; they are not GUI or
  per-display evidence. `scripts/check.sh` and `--self-test` have different scopes.
- A successful private-API callback or `NSPanel.isVisible` is not proof that a
  user sees an icon. Use actual screenshots, interactions, and live state.
- A section implemented only per app is not full per-icon parity. Independent
  sections, persistent physical boundaries, and target-app restart behavior
  remain requirements even where the current backend passes a narrower check.
- Captured images are local and stay in memory. No accounts, paid tiers, or
  analytics are required for any feature.
- Keep unimplemented and unverified rows visible until authoritative evidence
  supports completion. The overall Ice-parity goal remains active.

See [appearance research and verification](APPEARANCE_RESEARCH.md) for rendering evidence and its remaining limits.

See [spacing research and verification](SPACING_RESEARCH.md) for native preference and rendering evidence.

See [changing icon refresh](ICON_REFRESH.md) for native and GUI evidence and remaining capture limitations.

See [activation and interface lifetime](ICON_ACTIVATION.md) for native click, window tracking, and real-app evidence.

See [fuzzy search](ICON_SEARCH.md) for reference matching, intentional extensions,
installed query evidence, and remaining activation checks.
