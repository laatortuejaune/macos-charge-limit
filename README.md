# macos-charge-limit

A small macOS menu bar app to read and change the built-in **battery charge
limit** — 80 / 85 / 90 / 95 / 100 % — without opening System Settings.

<p align="center">
  <img src="docs/menu.png" width="196" alt="The menu, showing time remaining above the five charge levels with a checkmark on the active one">
</p>

It shows the current limit next to a battery icon, applies a new one in a single
click, stays in sync when you change the limit somewhere else, and reports how
long is left — on battery, or until charging stops at your limit.

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

So the time to a limit below 100 % is computed here. Scaling `AvgTimeToFull` by
the remaining percentage is the obvious approach and it is wrong: charging slows
sharply near the top, so the average it represents badly understates the speed of
the region we care about. Measured over a real charge, 53 → 64 % ran at
1.4 min/point against the 2.6 min/point that `AvgTimeToFull` implied — scaling it
would have promised 58 minutes for a stretch that took about 37.

The app extrapolates from the charge current instead, which holds while the
battery is still in constant-current charging — precisely the region below the
lowest available limit. On the same charge that method predicted 35 minutes
against roughly 37 actual. It is still an estimate, and it is shown as one:
rounded to 5 minutes and prefixed with `~`. At a limit of 100 % no computation
happens at all, and Apple's own untouched figure is shown without the tilde.

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
  App.swift             the menu bar UI
Resources/
  Info.plist            LSUIElement — no Dock icon, no window
  make-icon.swift       regenerates AppIcon.icns
  en.lproj, fr.lproj    English and French UI
Tools/
  power-probe.swift     dumps the raw power keys; how the above was measured
build.sh                swift build + hand-assembled .app bundle
```

Regenerate the icon with `swift Resources/make-icon.swift`.

## License

MIT — see [LICENSE](LICENSE).
