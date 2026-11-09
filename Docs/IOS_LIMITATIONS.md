# iOS execution and audio limitations

This file covers what AeroPA can and can't do on iOS, and the design choices that follow. Nothing here relies on private API or on behaviour App Review rejects.

## 1. Background execution

| Situation | What happens | Telemetry? |
|---|---|---|
| AeroPA in the foreground | Normal operation | ✅ |
| iPad Split View / Slide Over with Aerofly | Both apps are foreground | ✅ |
| Switched to Aerofly (full screen), **cabin ambience on** | AeroPA stays running under the `audio` background mode because it's actively playing audio | ✅ (needs device confirmation, see §4) |
| Switched to Aerofly, **ambience off** | iOS suspends AeroPA a few seconds after its last sound. Sockets stop delivering. | ❌ until AeroPA comes back to the foreground |
| Screen locked, ambience on | Same as background with audio | ✅ |
| Phone call / Siri / alarm | The audio session is interrupted, iOS may suspend the app, the scheduler pauses | ⚠️ resumes after the interruption ends |

Key points:

* **A UDP listener alone doesn't keep an app alive.** iOS suspends background apps, and a suspended process receives nothing. AeroPA never claims otherwise.
* The `audio` background mode applies only while the app is **actually playing audible audio**. The supported way to keep AeroPA running alongside Aerofly is the **cabin ambience loop**. It's a real, audible feature of the product, not a silent keep-alive trick. Apple rejects apps that play silence to stay alive, and AeroPA doesn't do that.
* If the user turns ambience off or sets its volume near zero, the dashboard shows a warning that background operation isn't guaranteed.
* When AeroPA returns to the foreground, `AeroflyUDPProvider.refreshAfterForeground()` recreates the listener if iOS tore it down. The connection then recovers automatically.
* AeroPA doesn't use Background App Refresh, BGTaskScheduler, VoIP or location modes. None of them fit this use case, and using them as a keep-alive would violate the App Review guidelines.

## 2. Local network

* iOS 14+ asks for **Local Network** permission the first time AeroPA listens. `NSLocalNetworkUsageDescription` is set.
* There's no API to query the permission state. AeroPA detects a denial from Network.framework errors (`kDNSServiceErr_PolicyDenied` / `EACCES` / `EPERM`). It then shows *Settings › Privacy & Security › Local Network* with a button to open Settings.
* **Broadcast vs unicast.** Receiving UDP **broadcast/multicast** on iOS requires the restricted `com.apple.developer.networking.multicast` entitlement, which needs Apple's approval. AeroPA doesn't assume it has that entitlement. **Set Aerofly's broadcast IP to the iPhone/iPad's own IP (unicast).** The Connection screen shows that IP. If you get the entitlement, add it to the target; no code changes are needed.
* No Bonjour browsing is done, so no `NSBonjourServices` entry is needed.

## 3. Audio session policy

* Category `.playback`, options `[.mixWithOthers]`:
  * AeroPA **never interrupts or ducks Aerofly's audio.** Both play together.
  * It plays with the silent switch on and on the lock screen.
  * AirPlay and Bluetooth A2DP routes are allowed by default. AVAudioEngine restarts after route changes (`AVAudioEngineConfigurationChange`).
* Ducking happens only *inside* AeroPA: ambience ducks to 35% under PA and callouts, and PA ducks to 50% under callouts.
* **"Duck the simulator during announcements" isn't offered.** iOS ducks other apps for as long as the ducking session is active, and un-ducking requires deactivating the session, which would stop the ambience that keeps AeroPA alive. Use Aerofly's own volume sliders to balance the mix.
* **Same-device caveat (needs device testing):** if Aerofly itself configures a non-mixable audio session, iOS may interrupt AeroPA's session when Aerofly comes to the foreground. AeroPA handles `AVAudioSession.interruptionNotification`: it suspends the scheduler and reactivates when allowed. **If iOS doesn't let both play together on your device, run AeroPA on a second device** (an iPhone next to the iPad running Aerofly). Unicast over Wi-Fi works the same way.

## 4. What needs confirming on real hardware

These can't be confirmed without Aerofly FS Global on a physical device, and the code handles each case defensively:

1. Whether Aerofly FS Global (iOS) exposes *Broadcast flight info to IP address*. It's documented for desktop Aerofly.
2. Whether Aerofly accepts `127.0.0.1` or needs the device's Wi-Fi IP when both apps run on one device.
3. Whether Aerofly's audio session mixes with others, which decides if both apps can play on the same device.
4. Whether iOS keeps delivering UDP to a backgrounded app that's playing audio. It does on current iOS versions for audio apps, but verify it with the steps in `TESTING_GUIDE.md` §3.
