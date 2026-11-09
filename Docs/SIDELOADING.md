# Installing AeroPA on your iPhone without Xcode (sideloading)

GitHub builds the app. Sideloadly, on your Mac, signs it with your own free Apple ID and installs it over USB.

## 1. Get the .ipa
1. Push to `main`, or open **Actions › Build IPA › Run workflow** on GitHub.
2. When the run is green, scroll to **Artifacts** and download **AeroPA-unsigned-ipa**. Unzip it to get `AeroPA.ipa`.

## 2. Install Sideloadly (once)
* Download it from the official site, **sideloadly.io**, and only from there.
* On macOS, Sideloadly asks you to install its Mail plug-in for anisette data, or to use its remote option. Follow its prompts.

## 3. Sideload
1. Connect your iPhone with a cable, unlock it, and tap **Trust This Computer**.
2. Open Sideloadly. Your iPhone appears under **iDevice**.
3. Drag `AeroPA.ipa` into Sideloadly.
4. Type your **Apple ID** in Sideloadly yourself, then click **Start** and enter your password and 2FA code when asked.
   * A free Apple ID is fine. If you'd rather not use your main account, create a separate Apple ID just for sideloading.
5. Wait for **Done**.

## 4. First launch on the iPhone
1. **Settings › Privacy & Security › Developer Mode** → On. The phone restarts; confirm when it asks.
2. **Settings › General › VPN & Device Management** → tap your Apple ID → **Trust**.
3. Open AeroPA and tap **Allow** for **Local Network**.

## Limits with a free Apple ID
* The app stops opening after **7 days**. Re-run Sideloadly with the same .ipa to renew it; your settings are kept. Sideloadly can auto-refresh over Wi-Fi if you turn that on.
* You can have at most 3 sideloaded apps at once.
* A paid developer account ($99/yr) lasts a year, and lets you use TestFlight instead.

## Quick test
* **No simulator:** Settings › Demo & testing › Use demo flight → Flight tab › Start Companion.
* **With Aerofly:** in Aerofly's Miscellaneous settings, turn on Broadcast flight info to IP address. Enter the IP shown in AeroPA › Settings › Connection, and port 49002.
