# Menu bar item activation and interface lifetime

Reference: Ice `MenuBarItemManager.swift` at `da2dd23`, particularly native
click creation, `temporarilyShow`, and `TemporarilyShownItemContext`.

During real-app validation on macOS 27.0.1, the Stats CPU result opened its
original CPU interface. WindowServer reported an ordinary layer-0 window; the
previous menu detector recognized only popup-menu/modal-panel layers and therefore
reported it closed. Macs Fan Control exposed a second defect: its original
menu opened, but Accessibility returned a failed press. A local interaction
trace recorded `pressReturned: false` with an empty pre-action window list, while
independent WindowServer metadata showed a new layer-101 fan menu. The old
failure path discarded tracking and restored all icons.

Activation now resolves the exact AX/process descriptor and verifies exposure
and the menu bar location before posting a native left click. The shared click
routine checks event-posting permission and released mouse buttons, sets mouse
down click state to 1 and up to 0, tags the events, and restores the pointer.
Tags suppress only this process's own menu bar monitor events. Click delivery
alone is not proof that the target performed its action.

Immediately before the click, after any native overflow expansion, the app
records the owning process's visible window IDs. After 250 ms it records the
first new window from that owner, matching Ice's approach. Menu/status layers
remain tracked while on screen; ordinary-layer interfaces remain tracked while
their app is active and the window is on screen. Existing and subsequently
opened windows do not prolong the reveal. The entry's process identity guards
against a terminated owner. After the minimum interval, a closed interface and
paused input release the temporary reveal and resume selected-app hiding. Ordinary windows without a supported
cancel action are left to the user to close or deactivate.

## Verification

- `--interface-check --report PATH` creates an existing normal-layer window and
  an owned status item that opens a second normal-layer window through the real
  activation path. The final signed app passed action observation, exclusion of
  the existing window, retention of the new interface despite the legacy detector
  returning false, and release/re-hide after closure.
- In the real fan-app test, native delivery returned true, window 17962 was
  captured and reported open, and independent metadata confirmed the original
  222×329 menu at (1499, 40), layer 101. Reopening NookBar canceled that menu and
  returned to the hidden strip; independent metadata confirmed the fan menu
  closed and the seven-item strip appeared.
- `--interaction-report PATH` appends local NDJSON at activation stages. It
  records app IDs, baseline/tracked window IDs, pending/visibility state, and
  delivery results, without screenshots or menu contents. It is developer-only
  and does not send data anywhere.
- Startup search had appeared at (8, 922) before its anchor was ready. Vertical
  placement now uses the screen's menu bar floor and safe area; horizontal
  dynamic/pointer/icon placement still uses the selected anchor. In the final
  startup check, independent metadata placed the 380×340 search window at
  (8, 45), below the 39-point menu bar, with both third-party test menus closed.
- Final native regressions passed 24-icon overflow capture/activation/restoration,
  two refresh cycles with all 24 independent image buffers changed, and the
  broader hide/reveal, live-entry resolution, removal, and rename checks.

This does not establish all third-party app interfaces, click variants, reused
window IDs, multiple app instances, fullscreen, other displays, or permission
revocation. System items and independent per-icon hiding remain parity work.
Temporary reveal now has a separate Advanced setting, `tempShowInterval`, matching
Ice's default of 15 seconds and UI range of 0–60 seconds. After the initial
deadline, an open interface postpones the next check by three seconds. Mouse
movement/scrolling within 250 ms, held mouse buttons, or held modifiers postpone
it by one second. This is independent of the general bar rehide strategy.
Scheduling uses monotonic system uptime so wall-clock changes do not shorten it.

The signed native interface check passed with the default 15-second minimum:
after early closure the reveal remained held, and selected-app hiding resumed
after the deadline. Isolated preference checks cover default, persistence,
zero/max bounds, corrupt values, and retry priorities. CUA confirmed the Advanced
tab, explanatory text, native numeric field and stepper with value 15. Physical
zero/max timing and all active-input combinations remain unverified.
