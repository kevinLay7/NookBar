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
| Hide/reveal selected items | App-wide public backend; owned R/D/L hiding/capture/activation verified; disposable divider independently hides foreign Stats Disk while CPU remains exposed, captures Disk via overflow, and restores original foreign order/exposure | Public independent control of multiple icons from one app; persistent per-icon membership; adaptive width selection and recovery; visible-control preservation; system icons; per-display verification |
| Hidden icon strip | Actual captured icons, separate buttons; live exposure checks; distinct collapsed identities; automatic native overflow capture/restoration and activation verified with 24 owned test icons; fresh reopen and three-second idle image refresh; changing overflow images verified across all 24 owned probes with panel retention and collapsed-state restoration | Foreign overflow items and their menus/popovers; system extras; other displays; transparent icon capture; eliminating native reveal during refresh; refresh/activation cancellation races; same-label replacement identity reuse; clipped/notch items; all click variants |
| Native menu bar reveal instead of strip | Both sections' reveal/toggle behavior verified through app controls and independent AX snapshots | Physical tray click and each automatic rehide strategy |
| Control icon | Native tray plus N fallback | All displays, fullscreen, automatic menu bar hiding, custom/show/hide icon options |
| Empty-space click and secondary context menu | Global and local event handling | Physical toggle and context-menu checks, modifier combinations |
| Hover and scroll activation | Configurable hover delay; directional scroll | Physical pointer/scroll checks, debounce, fullscreen sliding menu bar |
| Automatic rehide | Smart, timed, focused-app strategies | Real menu-close and focused-app checks, pointer leave/re-entry, disabled rehide |
| Bar position | Dynamic, pointer, icon settings; vertical position constrained below menu bar/safe area even with a startup placeholder anchor | Each display, desktop edges, fullscreen |
| Temporary icon/interface reveal | App-wide reveal; exact-entry native click; configurable 0–60-second minimum (default 15), 3-second interface retry and 1-second input retry; first-new-window tracking; owned layer-0 lifetime/existing-window exclusion and real fan-menu activation/cancellation verified | Independent per-icon reveal; physical zero/max-interval and active-input combinations; simultaneous interfaces; other app/window types; restarts and multiple instances |
| Global shortcuts | Native registration and recorder; hidden/always-hidden/search/bar-mode actions | Cross-app execution, conflicts, key-up repeats; remaining app-menu action |
| Icon search | Real Stats CPU interface and selected fan-menu activation observed; native hit-checked clicks and first-new-window interface tracking; captured third-party icons; app/name/bundle filtering and keyboard navigation verified in CUA; fresh capture on reopen and three-second idle refresh preserving query/selection | Other app activation, Ice fuzzy scoring/ranking, selection/scroll preservation across changing result sets, always-hidden and system item coverage; eliminating native reveal during refresh |
| Visible, hidden, always-hidden sections | Persistent app assignments, separate strips and native reveal verified | Physical Option activation, independent per-icon membership |
| Drag layout and ordering | Public Arrange Icons window; button movement of Stats CPU/RAM verified in both directions, with NookBar relaunch persistence and close/re-hide checks; user verified physical CPU/RAM row dragging | Other physical row pairs; drag between sections; identity across target-app restarts; system items; each display; Command-drag reveal-all behavior |
| Launch at login | Native Service Management option | Registration status and actual login; approval-required/error states |
| Startup visibility | Saved hide-on-launch option | Signed installed-app relaunch and startup permission failure |
| App launches/exits, sleep, lock, Spaces | Restore/resume and running-app reconciliation | Real lifecycle and multiple-display checks; fail-open restoration |
| Menu bar spacing | Native host-specific spacing/padding settings, −16…+16 offset, defaults reset, prior-value restoration, and selective graceful app relaunch; visible owned icons verified at default, −8, −16, and +16; relaunch success/refusal and cancellation tested | Full third-party/system-icon coverage, other displays, logout behavior, launch failures, and custom pre-existing value GUI restoration |
| Menu bar appearance | Native Appearance settings and renderer: full/split shapes, independent caps, notch inset, shadow, border, solid/gradient tint, and separate light/dark profiles; actual full/split rendering and held-preview restoration verified on built-in display | Other displays, Spaces/fullscreen, automatic theme changes, moving wallpapers, permission revocation, auto-hide resume, and combinations with fallback control/hiding |
| Hide application menus when more room is needed | Missing | Native behavior, Dock visibility and restoration |
| Permissions and diagnostics | Accessibility and capture prompts | Revocation, stable signing, actionable errors and no stuck invisible control |
| Updates and distribution | Public GPL source; local signed app | GitHub downloads, signing/notarization, update checks and installation |

## Verification rules

See [per-icon research](PER_ICON_RESEARCH.md) for the wide-divider experiment,
Accessibility limitations, and native overflow/drag leads. See also the
[application-menu investigation](APPLICATION_MENUS_RESEARCH.md), whose tested
activation variants did not establish menu bar ownership. The divider experiment does
not provide a working independent-item backend.

- Build/logic checks cover only the branches they exercise; they are not GUI or
  per-display evidence. `scripts/check.sh` and `--self-test` have different scopes.
- A successful private-API callback or `NSPanel.isVisible` is not proof that a
  user sees an icon. Use actual screenshots, interactions, and live state.
- A section implemented only per app is not full per-icon parity. This backend
  limitation remains a research task, not a reason to remove the requirement.
- Captured images are local and stay in memory. No accounts, paid tiers, or
  analytics are required for any feature.
- Keep unimplemented and unverified rows visible until authoritative evidence
  supports completion. The overall Ice-parity goal remains active.

See [appearance research and verification](APPEARANCE_RESEARCH.md) for rendering evidence and its remaining limits.

See [spacing research and verification](SPACING_RESEARCH.md) for native preference and rendering evidence.

See [changing icon refresh](ICON_REFRESH.md) for native and GUI evidence and remaining capture limitations.

See [activation and interface lifetime](ICON_ACTIVATION.md) for native click, window tracking, and real-app evidence.
