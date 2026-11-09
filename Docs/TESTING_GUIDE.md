# Testing guide

## 1. Automated tests

```bash
# With Xcode
swift test                                   # core package (macOS host)
xcodebuild test -scheme AeroPA -destination 'platform=iOS Simulator,name=iPhone 15'

# Without Xcode (Command Line Tools only): uses a minimal XCTest shim
./Tools/run_tests_without_xcode.sh
```

70 tests cover:

| Area | Suite |
|---|---|
| UDP packet parsing, invalid packets (fixtures) | `ForeFlightParserTests` |
| Unit conversion, derived VS, stale attitude | `TelemetryNormalizerTests` |
| Stale, lost and recovery state machine, packet rate | `ConnectionLivenessTests` |
| **Real Network.framework listener over loopback**: receive, reject, stale → lost → recover, disconnect | `AeroflyUDPProviderTests` |
| Debouncing, full flights (full telemetry **and broadcast-only packets through the real parser**), rejected takeoff, go-around, manual mode, reset, dedup | `FlightPhaseEngineTests` |
| Delays, dedup, cooldown, phase-validity cancellation, categories, missing files → speech, missing without fallback, placeholders, weighted variants | `AnnouncementEngineTests` |
| All 7 bundled packs load, every language covers every PA cue, generic SFX present, user-pack override, broken manifest | `AirlinePackLibraryTests` |
| Airbus vs Boeing phraseology, per-type Vr, capability gating, single-sample protection, once per flight, climb/descent ordering | `CopilotEngineTests` |
| Priorities, interruption, non-interruptible, expiry, ducking, lead-in chime, failure skip, suspend/resume | `AudioSchedulerTests` |
| Whole pipeline from demo flight to ordered PAs and callouts, Core Data persistence, inactive companion, reset | `CompanionIntegrationTests` |

## 2. Network path without Aerofly (real device)

The replay tool sends the same datagram format Aerofly sends:

```bash
swift run aeropa-udp-replay --host <device Wi-Fi IP> --speed 1
swift run aeropa-udp-replay --host <device IP> --file my_capture.txt --rate 5
```

1. Run AeroPA on the device. Source: *Aerofly FS (UDP)*. Accept the Local Network prompt.
2. Start the replay. *Connection* should change from **Searching** to **Connected**, the simulator should read `Aerofly FS 4`, and the rate should be about 5 Hz.
3. Press **Start Companion**. At `--speed 1` a full flight takes about 65 minutes. Phase holds use real time, so speeds above 1× skip the timed holds; that's expected.
4. Stop the replay. Expect **Signal interrupted** after 3 s and **Connection lost** after 15 s. Restart the replay and expect **Connected** again with no user action.

## 3. Real Aerofly flight checklist

**Setup**
1. Connect both devices to the same Wi-Fi network (or use one device; see step 3).
2. In AeroPA open *Settings › Connection* and note the **Wi-Fi** address.
3. In Aerofly FS open *Settings › Miscellaneous*, turn on **Broadcast flight info to IP address**, enter that address, and keep port **49002**. For the same device, try `127.0.0.1` first.
4. In AeroPA open *Flight setup*: pick the aircraft that matches Aerofly, the airline and language, fill in the flight details, and **enter the destination field elevation** (needed for 1000/500/minimums).
5. Within a few seconds, *Connection › Live diagnostics* should show XGPS and XATT counts increasing. **Record the "Last datagram" text** and compare it with `Docs/AEROFLY_TELEMETRY.md` §2.

**Flight**
| Step in Aerofly | Expected in AeroPA |
|---|---|
| Sit at the gate, press Start Companion | Boarding after about 5 s: boarding PA, cabin ambience |
| Pushback (track opposite heading) | Pushback: "doors armed", welcome after 20 s |
| Stop after the push | Engine start (inferred after 8 s stopped): safety briefing |
| Taxi > 3 kt | Taxi: cabin preparation |
| Takeoff roll > 40 kt | Takeoff: "seats for takeoff". FO: 80/100 kt, V1, Rotate (ground-speed based, "estimated") |
| Climb > 100 ft, VS > 300 | Initial climb: "Positive rate/climb", procedural "Gear up" |
| Through 10,000 ft | Seatbelt chime and "seatbelt sign off" PA |
| Level for 60 s above 6,000 ft AGL | Cruise: captain PA, meal service at +5 min |
| Descend > 500 fpm for 30 s | Descent: captain PA |
| Through 10,000 ft descending | "Prepare cabin for landing" |
| Within 4,000 ft of destination elevation, < 250 kt | Approach: "seats for landing", 1000 / 500 / minimums (if elevation entered) |
| Touchdown | Landing: FO spoilers/reverse/decel (Airbus) or speedbrakes/reversers (Boeing) |
| Below 40 kt | Taxi in: arrival welcome |
| Stopped for 30 s | Parked: disarm doors, disembarkation |

**Background check** (iOS §4.4): with the companion running and ambience on, switch to Aerofly full screen for at least 2 minutes during climb. Expected: announcements keep playing at the right moments, and the *Live* timeline has no "Connection lost" entries. Then repeat with ambience **off**. Expected: AeroPA goes quiet within seconds and reconnects when brought back to the foreground. Record both results.

**Audio coexistence check:** confirm Aerofly's engine audio keeps playing while AeroPA speaks (mixWithOthers). If either app silences the other, note which one and use a second device for AeroPA.

## 4. Demo mode (no simulator at all)

*Settings › Demo & testing* → **Use demo flight** (badged DEMO everywhere):
* Scripted gate-to-gate flight with a 1–32× speed control and a jump-to-leg menu.
* **Aerofly fields only**: rehearses the exact real-device field set.
* Manual mode: sliders for altitude, speed, VS and heading, plus ground, gear, engines and flaps.
* Force any phase, play any announcement or callout, and inspect raw telemetry.
