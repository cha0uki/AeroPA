# AeroPA

A native iOS flight companion for **Aerofly FS**. AeroPA listens to Aerofly's live flight-data broadcast, works out the flight phase, and plays the matching airline cabin announcements, first-officer callouts and cabin sounds automatically.

Swift · SwiftUI · AVFoundation · Network.framework · Core Data · iOS 17+ · iPhone and iPad

> AeroPA isn't affiliated with IPACS/Aerofly or with any airline. It ships no airline recordings or logos. See `Docs/AUDIO_PACKS.md`.

## What works today

* **Real Aerofly integration:** a Network.framework UDP listener (port 49002) for Aerofly's *Broadcast flight info* datagrams (ForeFlight `XGPS`/`XATT`). It validates, normalises and checks liveness (connected / interrupted / lost / auto-recover), and shows diagnostics. → `Docs/AEROFLY_TELEMETRY.md`
* **Flight-phase engine:** 15 phases with debouncing, hysteresis and capability awareness. It works with the limited Aerofly field set (no gear, flaps, engines, IAS or on-ground flag) and also handles rejected takeoff, go-around and manual override.
* **Announcement engine:** manifest-driven, multi-language (EN/FR/AR/DE/TR), weighted variants, priorities, cooldowns, once-per-flight dedup, phase-validity cancellation. Missing recordings fall back to a synthesised voice, which is always labelled as such.
* **Copilot engine:** profiles for the A320 family, A350, 737, 777 and 787 with type-specific phraseology and speeds. Each callout is enabled only when the telemetry it needs is available.
* **Audio:** AVAudioEngine with four channels (PA, first officer, ambience, SFX), per-channel volume, ducking, crossfades, "cabin speaker" and "interphone" EQ, lead-in chimes, priority queues with expiry, interruption handling, and AirPlay/Bluetooth routes. It mixes with Aerofly and never ducks it.
* **Seven airline packs** (Air France, Royal Air Maroc, Emirates, Qatar Airways, Lufthansa, British Airways, Turkish Airlines) with original scripts and empty slots for your own licensed recordings. Original synthesised chimes and cabin ambience are included.
* **Demo mode:** a full gate-to-gate simulated flight, an "Aerofly fields only" rehearsal mode, manual sliders, phase forcing, cue triggers and a telemetry inspector. It's always badged DEMO.
* **70 automated tests**, including real UDP loopback and full-flight runs.

## Requirements

* Xcode 15 or later (iOS 17 SDK)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) only if you change `project.yml`. The generated `AeroPA.xcodeproj` is included.
* An Apple developer team, to run on a device (Local Network and background audio need a real device for meaningful testing)

## Build and run

```bash
open AeroPA.xcodeproj           # select the AeroPA scheme
# set Signing & Capabilities › Team, choose your iPhone/iPad, Run
```

If you edit `project.yml`:

```bash
xcodegen generate
```

## Connect to Aerofly

1. Put AeroPA and Aerofly on the same Wi-Fi network, or the same device.
2. AeroPA: *Settings › Connection* shows this device's IP address.
3. Aerofly: *Settings › Miscellaneous* → **Broadcast flight info to IP address** = on, IP = that address (or `127.0.0.1` on the same device), port **49002**.
4. The AeroPA pill turns green (**Connected · Aerofly FS …**).
5. Set the aircraft, airline, language and **destination elevation** in *Settings › Flight setup*, then tap **Start Companion**.

Running both apps on one device: keep **cabin ambience** on. It's what lets iOS keep AeroPA running in the background. → `Docs/IOS_LIMITATIONS.md`

## Tests

```bash
swift test                               # with Xcode
./Tools/run_tests_without_xcode.sh       # Command Line Tools only
swift run aeropa-udp-replay --host <device IP>   # drive a device over the real network path
```

See `Docs/TESTING_GUIDE.md` for the real-flight checklist.

## Documentation

| File | Contents |
|---|---|
| `Docs/ARCHITECTURE.md` | Component diagram, design decisions |
| `Docs/AEROFLY_TELEMETRY.md` | Protocol: what's verified, what isn't, field availability |
| `Docs/IOS_LIMITATIONS.md` | Background execution, local network, audio session |
| `Docs/TESTING_GUIDE.md` | Automated tests, replay, real-flight checklist |
| `Docs/AUDIO_PACKS.md` | Pack format, adding your own recordings, event map |

## Tools

* `Tools/generate_sounds.py`: regenerates the original chime and ambience WAVs
* `Tools/generate_icon.py`: regenerates the app icon
* `Tools/run_tests_without_xcode.sh`: runs the tests with only the Swift toolchain
