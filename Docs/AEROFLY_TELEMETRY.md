# Aerofly FS telemetry: what is verified and what is not

This file records what AeroPA's integration is based on. **Verified** means a public source confirms it. **Unverified** means the code handles it defensively, but you need to capture packets on a real device to confirm it (see `TESTING_GUIDE.md`).

## 1. Interfaces Aerofly offers

| Interface | Platform | Usable from iOS? | Status |
|---|---|---|---|
| External DLL SDK (`aerofly_fs_4_project_external_dll_sample`, aerofly.com/developer) | Windows desktop. It loads into the simulator process. | **No.** iOS can't load third-party code into another app. | Verified: the developer page lists only the "External DLL" for reading flight data. |
| "Broadcast flight info to IP address" (Miscellaneous settings) | Desktop Aerofly FS 2 / FS 4. Aerofly's devices page advertises broadcasting "to your iPad" for ForeFlight / Garmin Pilot / SkyDemon. | **Yes.** It's plain UDP. | Verified on desktop: ForeFlight's Aerofly FS 2 article says the port should stay at the default **49002**. |
| Same setting inside **Aerofly FS Global on iPhone/iPad** | iOS | Probably | **Unverified.** No public document confirms the setting exists in the mobile build, or what its default is. |

**No source mentions port 58585.** AeroPA doesn't treat it as special. It listens on 49002 by default, and the port can be changed in *Connection → Advanced*.

Community bridges such as *Aerofly FS4 Bridge* and *FSWidgets* run on the Windows PC and read data through the External DLL. They're not a model for an iOS receiver, and AeroPA doesn't depend on them.

## 2. Wire format: the ForeFlight "Simulator GPS/Traffic/Attitude" protocol

The broadcast uses ForeFlight's public text protocol: one ASCII message per UDP datagram, with fields separated by commas.

```
XGPS<sim-name>,<longitude>,<latitude>,<altitude MSL metres>,<true track deg>,<ground speed m/s>
XATT<sim-name>,<true heading deg>,<pitch deg>,<roll deg>[,optional extra fields…]
XTRAFFIC<sim-name>,<icao>,<lat>,<lon>,<alt ft>,<vs fpm>,<airborne 0/1>,<heading>,<speed kt>,<callsign>
```

* Longitude comes **before** latitude in `XGPS`.
* `XGPS` altitude is in **metres** MSL. Ground speed is in **metres per second**.
* ForeFlight's spec has GPS at roughly 1 Hz and attitude at a higher rate. Aerofly's actual rates are **unverified**, so AeroPA measures the packet rate and shows it on the Connection screen.
* Pitch sign convention (positive = nose up) and roll sign (positive = right wing down) follow the ForeFlight spec. Confirm both with a capture.
* `<sim-name>` is free text, for example something like `Aerofly FS 4`. AeroPA shows it as the "Simulator" and flags whether it contains "aerofly".

### Validation done by `ForeFlightMessageParser`
* The datagram must be ≤ 512 bytes of valid UTF-8/ASCII. Trailing `\r\n` and whitespace are stripped.
* The prefix must be `XGPS`, `XATT` or `XTRAFFIC`. Anything else is rejected as `unknownMessageType`.
* Minimum field counts: XGPS 6, XATT 4, XTRAFFIC 10. Extra XATT fields are tolerated.
* Every numeric field must parse as a finite `Double`.
* Range checks: lat ±90, lon ±180, altitude −500…25 000 m, ground speed 0…600 m/s, angles −360…360 (normalised to 0..<360 for headings), pitch ±90, roll ±180.

Fixtures for all of these cases live in `Tests/AeroPACoreTests/Fixtures`.

## 3. Field availability

| Field AeroPA wants | Source over the broadcast | Capability flag |
|---|---|---|
| Position | XGPS lat/lon | `position` |
| Altitude MSL | XGPS (m → ft) | `altitudeMSL` |
| Ground speed | XGPS (m/s → kt) | `groundSpeed` |
| Track | XGPS | `track` |
| Heading / pitch / bank | XATT | `heading`, `pitch`, `roll` |
| Vertical speed | **Derived** by least-squares slope of altitude over a 3 s window | `verticalSpeed` (derived) |
| Indicated airspeed | **Not transmitted.** Ground speed can stand in as an estimate (setting, on by default), labelled "est." in the UI. | `indicatedAirspeed` absent |
| Landing gear | **Not transmitted** | absent |
| Flaps | **Not transmitted** | absent |
| Engine state | **Not transmitted** | absent |
| On-ground | **Not transmitted.** Inferred (see `FlightPhaseEngine`). | absent |
| Radio altitude / AGL | **Not transmitted.** Estimated from origin elevation (captured automatically) and destination elevation (entered by the user). | absent |
| Aircraft type | **Not transmitted.** The user picks it in *Flight setup*. | absent |

Every engine checks these capability flags. A callout or phase rule that needs a missing field is turned off and listed as unavailable in the UI. AeroPA doesn't make up those values.

## 4. Network behaviour on iOS

* AeroPA listens with an `NWListener` on UDP 49002 and sets `allowLocalEndpointReuse` so it can share the port with an EFB app.
* **Unicast is recommended.** Enter the iPhone/iPad's Wi-Fi IP, shown on AeroPA's Connection screen, as Aerofly's broadcast IP. iOS needs the restricted `com.apple.developer.networking.multicast` entitlement to receive broadcast/multicast datagrams. ForeFlight also notes that iOS receives UDP unicast more reliably than broadcast.
* Bonjour isn't used, because Aerofly doesn't advertise a service. So the Info.plist declares no `NSBonjourServices`. It does include `NSLocalNetworkUsageDescription`.
* **Aerofly on the same device:** the address to use (`127.0.0.1` or the device's own Wi-Fi IP) is **unverified**. Both are listed in the in-app help. See `IOS_LIMITATIONS.md` for the background-execution consequences.

## 5. How to verify on your setup

1. Turn on *Broadcast flight info to IP address* in Aerofly and enter the device IP, port 49002.
2. Open *Connection → Diagnostics* in AeroPA. It shows the raw last datagram, per-type counters, rejected-packet counters with reasons, and the measured Hz.
3. If the raw text differs from section 2, add the captured line to the fixtures and adjust `ForeFlightMessageParser`. It's the only file that knows the wire format.
