# Menu bar spacing

## References and design lock

Ice commit `da2dd23cdd70d287445cbe3dbb5628a4c3ad8c7e` defines two host-specific
preferences: `NSStatusItemSpacing` and `NSStatusItemSelectionPadding`. Its
manager uses base 16, offset −16…+16 in steps of 2, deletes both overrides at
zero, and relaunches menu bar apps. Its General settings pane explains the
relaunch/logout requirement. Source establishes the intended feature; runtime
checks below establish the measured macOS 27 behavior.

The existing NookBar native Settings and Appearance forms are the primary
visual target, preserving grouped controls, system typography, neutral surfaces,
and compact spacing. Prior Refero Desktop.fm/Raycast research remains bounded to
system-like typography and restrained layering, as documented in
APPEARANCE_RESEARCH.md. This feature needs code-native controls and no artwork.

| Decision | Source | Role |
| --- | --- | --- |
| Stepped compact/spacious slider, Apply, reset | Ice General settings | User control over the same native offset range |
| Separate Spacing tab | NookBar Settings/Appearance | Preserve readable existing form density |
| Explicit app selection before relaunch | Quit affects open apps and the user’s work | Identify which apps will restart and allow cancellation |
| Normal Quit, bounded refusal, manual recovery | Platform quit/save behavior | Leave refusing apps open, report failures, and avoid losing work |
| Restore prior settings | Existing system preferences can be customized | Preserve exact typed values and absence before first mutation |

## Implementation

CFPreferences reads/writes the global domain for the current user and host.
Both keys form one transaction with native readback. A failed write attempts to
restore the prior pair. The first pre-change pair is serialized into NookBar’s
UserDefaults before mutation, retaining both typed values and absent keys.
Restore Previous writes that snapshot, then removes it only after successful
verification. Reset removes current-host overrides, matching Ice’s zero setting.
Custom/mismatched native preferences are labeled as custom rather than inferred
as a known offset.

Apply saves the preference pair. Relaunch is a separate explicit action so the
user chooses its timing and apps. NookBar reveals icons for discovery, pauses
running-app reconciliation, and lists discovered third-party apps across the
current displays. Selection excludes NookBar and Apple service processes. Quit
requests start together, wait at most five seconds for termination, and reopen
terminated apps in the background. Refusing apps remain open and are reported.
NookBar resumes the requested hidden state on completion or cancellation and
rejects app Quit while a relaunch is in progress. System icons may need logout.

Settings launch flags honor the saved hide-on-launch option. The developer-only
`--spacing-probe` adds three numbered native items to the NookBar process, then
uses the ordinary app launch/hiding path. It neither reorders foreign icons nor
writes persisted status-item positions.

## Evidence

The isolated CFPreferences behavior checks verify both preference mutations,
round trips, restoring a serialized snapshot, deleting overrides, rejecting
invalid offsets, and rolling back a partially decoded transaction. They use a
fresh non-global domain, not the user’s system preferences.

On macOS 27.0.1, the installed native UI wrote both keys to 8 at offset −8.
A disposable third-party probe successfully quit and reopened with a new PID
when it was the only selected relaunch target. A quit-refusal test recorded the
probe delegate refusing termination, retained its PID, and produced NookBar’s
manual-relaunch message after the five-second deadline.

A crowded bar collapsed two standalone probe icons into native overflow. Its AX
coordinates were therefore insufficient for visual spacing validation. The
owned, variable-width numbered probes remained visible with saved apps hidden.
Their adjacent native intervals measured 32 pt at default, 24 pt at −8,
48 pt at +16, and 16 pt at −16; screenshots corroborated visible rendering.
Restoring the original-absent preferences and relaunching returned to 32 pt.
These local screenshots are not published in the repository.

REA with Hopper examined the current MenuBarAgent arm64e slice (SHA-256
`354702e02befee303e1dfaae99d44b62d125d96050931e86d8b2160dafe00557`).
Evidence `ev_cce010b7adae94fae447acd47fdfbdc63193c2118d1dea7f6730e6dc604cbd83`
found legacy NSStatusItemHost references and a preferred-position string.
The bounded NSStatusItem string search did not recover the two spacing keys
from this executable; it does not prove they are unused or identify the code
that reads them. The live preference/geometry checks establish the tested
behavior independently of that static search. The REA session was closed after
exporting its evidence to a local scratch report.

## Remaining limits

Broad third-party and system-item rendering, other displays, logout behavior,
custom pre-existing GUI restoration, launch failures, and interactions with
arrangement/appearance/native overflow still require validation. The standalone
probe’s absence while assessment-mode hiding was active also needs a fresh
membership-correlated test: the saved hidden list changed during this session,
so no root cause is assigned. Full Ice parity remains active.
