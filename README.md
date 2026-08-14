# macos-charge-limit

A small macOS menu bar app to read and change the built-in **battery charge
limit** — 80 / 85 / 90 / 95 / 100 % — without opening System Settings.

<p align="center">
  <img src="docs/menu.png" width="281" alt="The menu, mirroring the macOS battery panel, with a charge-limit segmented control added">
</p>

It mirrors the macOS battery menu — same drawn gauge, same panel layout — with
the charge limit added to it, so you can turn Apple's own battery icon off and
stop having two of them side by side.

## Why

macOS 26.4 turned the old "80 % limit" switch into a real setting with five
levels, buried in **System Settings → Battery → ⓘ next to Charge**. That is four
clicks away and gives no at-a-glance readout. This puts it in the menu bar.

## Requirements

- An Apple silicon Mac with a battery
- macOS 26.4 or later (earlier versions only had the on/off 80 % toggle)
- Command Line Tools. **Xcode is not required.**

## Install

```bash
git clone https://github.com/laatortuejaune/macos-charge-limit.git
cd macos-charge-limit
./build.sh
cp -R BatteryLimitMenu.app ~/Applications/
open ~/Applications/BatteryLimitMenu.app
```

Enable *Launch at Login* from the app's own menu if you want it to stick around.

## Updating

```bash
cd macos-charge-limit
git pull
./build.sh
pkill -f 'BatteryLimitMenu.app/Contents/MacOS'
open BatteryLimitMenu.app
```

The `pkill` line is the one people skip. `build.sh` replaces the bundle but never
touches the process already running from it, and `open` will not start a second
one — it just activates the copy that is already there. Skip the quit and you
keep running the old build while believing you upgraded.

Nothing else needs redoing: the bundle path does not change, so *Launch at Login*
survives an update even though the code signature changes with every build.

The app is ad-hoc signed, not notarized — fine when you build it yourself, but
macOS will complain if you move a prebuilt copy between machines.

---

## How it works

This is the part worth reading. The charge limit is **not** exposed anywhere
obvious, and every documented route is a dead end.

### What does not work

Verified empirically on macOS 27.0, not assumed:

| Route | Result |
| --- | --- |
| `ioreg -rc AppleSmartBattery` | Nothing. All ~60 properties dumped. `MaxCapacity` is battery *health*; `CarrierMode` is shipping mode. |
| `ioreg -rc AppleSmartBatteryManager`, `IOPMPowerSource` | Nothing. |
| `system_profiler SPPowerDataType` | Nothing. |
| `pmset` | Cannot read or write it. |
| Configuration profile / MDM | No key for it. |

The reason all of these fail is the same: **the charge limit is not a property of
the hardware.** It is application state owned by a daemon.

### The actual mechanism

Internally the setting is called **MCL — Maximum Charge Level**. It lives in the
PowerUI daemon, reachable over XPC through a private framework:

```
System Settings ─┐
this app         ├─► PowerUISmartChargeClient ──XPC──► PowerUI daemon ──► charge controller
Shortcuts action ┘      (PowerUI.framework)
```

The app takes the exact path System Settings takes. **No root, no helper tool, no
kext, no SMC writes** — because the privileged party is the daemon, not us. We
are not asking for permission to write the SMC; we are asking an already
authorised system service to do it.

`PowerUISmartChargeClient` lives in
`/System/Library/PrivateFrameworks/PowerUI.framework`, which exists only inside
the dyld shared cache — so it cannot be linked against, only `dlopen`ed and
reached through the Objective-C runtime.

| Purpose | Selector |
| --- | --- |
| Create the client | `-initWithClientName:` |
| Is it available? | `-isMCLSupported` |
| **Read the limit** | `-getMCLLimitWithError:` → `unsigned char` |
| **Write the limit** | `-setMCLLimit:error:` |
| Offered levels | `-availableChargeLimitsWithError:` → `(80, 85, 90, 95, 100)` |
| Change signal | Darwin notification `com.apple.powerui.smartchargestatuschanged` |

The levels are asked for rather than hardcoded, so the menu follows if Apple ever
changes them. The Darwin notification fires whichever app made the change, which
is what keeps the menu bar in sync with System Settings for free — no polling.

### Five traps

**1. `-init` returns a mute client.** It succeeds and hands back a perfectly live
object, but with no XPC connection: every call answers `false` / `0` / empty
array, and the `NSError` is left `nil`. Silent, and easy to mistake for "the
machine doesn't support it". Only `-initWithClientName:` sets up the connection.

**2. `currentChargeLimit:` is not the setting.** It reports the limit *in effect
right now* and reads 100 whenever the machine is unplugged. Only
`-getMCLLimitWithError:` tracks what the user chose. This was confirmed by
changing the value in System Settings and watching which key moved.

**3. 100 % means "no limit".** Writing 100 disables MCL
(`-isMCLCurrentlyEnabled:` drops to 0), but `-getMCLLimitWithError:` still
returns 100 — so a single key is enough to drive the whole UI.

**4. `@main` on an `NSApplicationDelegate` starts the run loop without assigning
the delegate.** The app runs, mute and invisible, with no error anywhere. Hence
the explicit entry point in [`App.swift`](Sources/BatteryLimitMenu/App.swift).

**5. `unsafeBitCast` to an `@objc` protocol checks nothing.** It is the neat way
to call a class you cannot link against, but the compiler stops helping: if any
selector is missing the message still goes out, and the process dies on
`NSInvalidArgumentException: unrecognized selector`. Since every selector here
belongs to a private framework that can change without notice, the client is
built only after `-respondsToSelector:` has cleared **all** of them. Miss one and
the client is `nil`, which the UI already knows how to present.

### Time remaining, and why it has to be computed

Two more things had to be measured rather than assumed. The probe used for it is
[`Tools/power-probe.swift`](Tools/power-probe.swift).

**No system counter targets the charge limit.** `AvgTimeToFull` always counts to
100 %, whatever the limit is set to. Flipping the limit 80 → 100 → 80 during an
actual charge moved it by exactly zero minutes:

```
17:44:51  limit 80    54%   AvgTimeToFull = 117 min
17:45:06  limit 100   54%   AvgTimeToFull = 117 min
17:47:51  limit 100   56%   AvgTimeToFull = 118 min
17:48:06  limit 80    56%   AvgTimeToFull = 118 min
```

**`IOPowerSources` returns nothing on macOS 27.** `Time to Empty` and `Time to
Full Charge` both read `-1` permanently, on battery and while charging; `pmset`
agrees, printing `no estimate`. Only `AppleSmartBattery` in the IORegistry has
usable figures, so that is what the app reads. `IORegistryEntryCreateCFProperties`
is public API; the key names are not.

**And the raw figure is far too jumpy to show.** `TimeRemaining` tracks the power
draw of the moment, so it swings with whatever the machine happens to be doing.
Logged over an evening it ranged from 106 to 7427 minutes — a factor of 70 — with
83 minutes of average change between readings taken 45 seconds apart. That is
presumably why `pmset` declines to print an estimate at all here.

So the app averages it. `PowerTelemetryData` carries a running total of power
drawn plus the number of samples behind it, ticking at about 0.96 Hz. Subtracting
two readings therefore yields the mean draw over exactly the interval between
them, with nothing to sample and no timer to run — the previous reading is simply
remembered. Checked against a 180-second window: 3427 mW that way against 3473 mW
for the true mean of the instantaneous values, 1.3 % apart. Autonomy is then the
remaining energy over that mean rather than over the current instant.

Measured over seven readings a minute apart, that takes the spread from a factor
of **2.46** down to **1.20**, and the average jump between consecutive readings
from **74 minutes to 16**. The window widens from 30 seconds up to 10 minutes
before re-anchoring, which keeps it responsive to a change of activity without
chasing every spike.

So the time to a limit below 100 % is computed here. Scaling `AvgTimeToFull` by
the remaining percentage is the obvious approach and it is wrong: charging slows
sharply near the top, so the average it represents badly understates the speed of
the region we care about. Measured over a real charge, 53 → 64 % ran at
1.4 min/point against the 2.6 min/point that `AvgTimeToFull` implied — scaling it
would have promised 58 minutes for a stretch that took about 37.

The app extrapolates from the charge current instead. Calibrated against a full
20 → 80 % charge (58 minutes, 237 samples): **median error 3 minutes, mean bias
−0.8**. It is still an estimate, and it is shown as one: rounded to 5 minutes and
prefixed with `~`. At a limit of 100 % no computation happens at all, and Apple's
own untouched figure is shown without the tilde.

The same calibration corrected two assumptions. Constant-current charging does
not extend all the way to 80 % — on this machine the current tapers from about
69 % (6.35 A down to 4.5 A), which costs the mid-charge prediction a few minutes
of optimism. And the first minute after plugging in is a ramp: `Amperage` is
filtered and refreshed about once a minute, so right after plug-in it can still
read negative. The app used to conclude "adapter can't keep up" during that
window, which is exactly wrong at exactly the moment the user looks; a negative
current now has to persist for 90 seconds before that verdict is shown, and the
window reads "Estimating…" instead.

### Standing in for the system battery menu

The menu bar gauge is drawn rather than picked from SF Symbols, because **no
`battery.*` symbol supports variable value** — checked across all six, while
`wifi` and `speaker.wave.3` do. Apple draws its own for the same reason, and
drawing gives a continuous fill instead of five fixed steps. The image is a
template, so the fill is carried by alpha alone and the whole thing follows light
and dark mode by itself.

The bolt is not drawn: Control Centre ships `battery-bolt` and `battery-bolt-mask`
in its asset catalogue, and both load at runtime out of
`/System/Library/CoreServices/ControlCenter.app` — the system's own artwork, read
off the machine, nothing copied into this repo. The mask is a pre-thickened copy
of the glyph, so the ring around the bolt is the system's to the pixel. It is
punched out with `.destinationOut`, which clears only where the source is opaque;
`.clear` would have wiped the whole rect. If that bundle ever moves, the code
falls back to `bolt.fill` with a ring built by offsetting the glyph around a
circle — scaling it up instead, which was the first attempt, gives a ring that is
thick far from the centre and vanishes near it, because a scale moves each edge
outward in proportion to its distance rather than by a fixed amount.

The cap comes from `battery-cap` too — it is a dome, flat against the body and
bulging outward, not the uniform rounded bar it looks like at a glance.

**One deliberate difference from the system icon.** macOS keeps showing the bolt
whenever the machine is plugged in, including once charging has stopped at the
limit — the icon then claims a charge that is not happening (`IsCharging = No`,
`Amperage = 0`). This app draws `battery-plug` in that state instead, which is
the glyph Apple ships for it. Bolt means charging, plug means plugged and idle,
so the real state is readable from the menu bar without opening anything. The
`battery-outline` image is the one piece not used: it is the hollow style the
panel still uses, whereas the menu bar icon is a solid capsule.

Every dimension is measured rather than eyeballed, by thresholding a screen
capture of both icons and comparing bounding boxes: body 23 × 12, cap 1.5 × 4.5
with a 1 pt gap, bolt 14 pt tall. That last one is the catch — the bolt asset's
visible glyph is only 12 pt, so the system scales it up, which is both why the
bolt overhangs the body and why its ring is thicker than the asset's own.

The panel repeats what the system one shows: level, power source, charge state,
Low Power Mode, and a way into Battery Settings. **Low Power Mode is read-only.**
`_PMLowPowerMode.setPowerMode:fromSource:` never calls back and changes nothing,
including from a signed bundle; the daemon checks the caller's entitlement, which
no third-party app can grant itself and `sudo` does not bypass. Clicking the row
opens Battery Settings, where it can be changed. The "apps using significant
energy" list is left out: it needs a sampling pass on every open, for the least
consulted part of the panel.

To hide Apple's own battery icon, turn it off in System Settings → Control Centre
→ Battery.

### Preventing sleep, and where it stops

`caffeinate` is not a mechanism of its own: it holds IOKit power assertions and
then waits. `IOPMAssertionCreateWithName` is public and needs no privilege, which
puts it in the same family as everything else here — ask the system, don't go
around it. No helper tool, no root.

Two assertions are held together, because holding only the first leaves a gap:

| Assertion | Covers |
| --- | --- |
| `PreventUserIdleSystemSleep` | the idle timer from Battery Settings |
| `PreventSystemSleep` | system sleep while power is connected |

They are held or dropped as a pair. A partial state — idle sleep blocked but
system sleep not — is real, and no checkmark can represent it honestly, so a
refusal on either one rolls the other back and reports the failure.

**Assertions do not cover a closed lid.** Closing the display triggers clamshell
sleep, which overrides them; the only lever is `pmset -a disablesleep`, and it
requires root.

> Unlike the rest of this file, that sentence is **not** measured on the
> machine — it is the documented behaviour, not an observation. Treat it as
> unverified until someone runs the check.

So the lid is opt-in, and off by default. **The app itself still asks for no
privilege**: it ships no helper tool, no daemon, and nothing setuid. What it
relies on instead is a sudoers rule you install once, by hand:

```bash
Tools/install-sleep-helper.sh            # one sudo, once
Tools/install-sleep-helper.sh uninstall  # and back out
```

What that grants is deliberately tiny — one account, two exact commands with
their arguments spelled out, so the right cannot be used to run `pmset` for
anything else:

```
you ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

The script validates the rule with `visudo -c` **before** installing it. That step
is not optional: a typo in a `/etc/sudoers.d` file breaks `sudo` outright,
including the `sudo` you would need to repair it.

Without the rule the app still works — it covers everything except the lid, and
the menu says so on its own line rather than showing a ticked box next to a Mac
that sleeps the moment you close it.

### One asymmetry worth knowing

The two mechanisms do not fail the same way, and the difference is the whole
reason the code has the shape it does.

An assertion dies with the process holding it. `disablesleep` is a **system
setting**: it outlives the app, and it survives a reboot. Left behind, it gives a
laptop that never sleeps again with nothing on screen to explain why — one that
cooks itself in a closed bag. Two guards, therefore:

- **On quit**, `applicationWillTerminate` clears it. The lid setting goes first,
  since it is the only one of the two that would otherwise persist.
- **On launch**, the app reads the real setting and *adopts* it if it is already
  on — from a previous run that crashed, or from a terminal. Ignoring it would
  mean showing an unticked box in front of a Mac that will not sleep, from the
  one place that could turn it back off.

That is also why the menu reads `pmset -g` for the true value rather than
trusting what it thinks it did.

The assertions carry a name, so the toggle is auditable from a terminal without
having to trust the checkmark:

```
$ pmset -g assertions
   PreventUserIdleSystemSleep     1  BatteryLimitMenu
   PreventSystemSleep             1  BatteryLimitMenu
```

The menu also reads `IOPMCopyAssertionsStatus`, which counts assertions across
the whole system, and subtracts its own. That is what lets it tell *"I am holding
this"* apart from *"something else is"* — a `caffeinate` forgotten in a terminal,
a video call. Without it, an unchecked box would be claiming the Mac is free to
sleep while it plainly isn't.

And to check the lid half, which is a setting rather than an assertion:

```
$ pmset -g | grep SleepDisabled
 SleepDisabled          1
```

### About the Shortcuts route

macOS 26.4 also added a `SetBatteryChargeLimitAction` Shortcuts action — it is in
`ActionKit`, not in the battery settings extension where you would look first. It
works, and `shortcuts run "name"` can drive it from a script, but it sits one
layer *above* the same API, offers no way to read the current value, and would
mean creating one shortcut per level by hand. The direct call is strictly better.

## Caveats

`PowerUI` is a **private framework**. A macOS update can rename the class or
change its selectors at any time, and one day it will.

What that costs is bounded on purpose. The client is only constructed once the
class resolves *and* every selector the app sends has been confirmed present; if
anything is missing the client is `nil`, the menu reads *Charge limit not
supported* and the icon shows `—`. So a future rename degrades the app instead of
crashing it. This is deliberate rather than incidental — see trap 5 above.

The app cannot ship on the Mac App Store, for the same private-API reason.

Verified on macOS 27.0 (build 26A5388g), Mac17,5, Apple silicon. That is one machine
and one OS version: on anything else, treat "it works" as unproven. `Info.plist`
sets `LSMinimumSystemVersion` to 26.4, so macOS itself declines to launch it
below the version where the setting exists.

## Project layout

```
Sources/BatteryLimitMenu/
  ChargeLimit.swift     the PowerUI bridge: read, write, change notification
  BatteryTime.swift     time remaining, and the estimate to the limit
  BatteryGauge.swift    the drawn gauge, and the system glyphs it borrows
  SleepGuard.swift      the sleep-prevention toggle: IOKit power assertions
  App.swift             the menu bar UI
Resources/
  Info.plist            LSUIElement — no Dock icon, no window
  make-icon.swift       regenerates AppIcon.icns
  en.lproj, fr.lproj    English and French UI
Tools/
  power-probe.swift     dumps the raw power keys; how the above was measured
  install-sleep-helper.sh  the one-time sudoers rule for closed-lid coverage
build.sh                swift build + hand-assembled .app bundle
```

Regenerate the icon with `swift Resources/make-icon.swift`.

## License

MIT — see [LICENSE](LICENSE).
