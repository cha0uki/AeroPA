# Airline audio packs

**Licensing rule:** packs may contain only original recordings, recordings you've licensed, or audio you made yourself. Don't add airline recordings you don't have the rights to. Bundled packs are fan-made scripts, carry a non-affiliation notice, and contain no airline audio or logos.

## Folder structure

```
AirlinePacks/<pack-id>/
  manifest.json
  PA/        welcome_en.m4a, welcome_fr.m4a, ...
  Copilot/   v1.m4a, rotate.m4a, ...
  SFX/       chime.wav, cabin_ambience.m4a, ...
  artwork.png   (optional, licensed)
```

Install: in the Files app, open *On My iPhone › AeroPA › AirlinePacks* and copy the folder in. Then tap *Airlines › Rescan packs*. A user pack with the same `id` replaces the bundled one.

## manifest.json

```json
{
  "schemaVersion": 1,
  "id": "my-airline",
  "name": "My Airline",
  "shortCode": "MA",
  "brandColorHex": "#123456",
  "artwork": "artwork.png",
  "languages": ["en", "fr"],
  "defaultLanguage": "en",
  "speechVoices": { "en": "en-GB", "fr": "fr-FR" },
  "placeholders": { "airline": "My Airline" },
  "inheritSharedScripts": true,
  "cues": {
    "pa.welcome": {
      "channel": "pa", "priority": 50, "leadIn": "sfx.chime",
      "variants": [
        { "language": "en", "file": "PA/welcome_en_1.m4a", "weight": 2 },
        { "language": "en", "file": "PA/welcome_en_2.m4a" },
        { "language": "fr", "file": "PA/welcome_fr.m4a", "text": "Bienvenue à bord…" }
      ]
    },
    "copilot.v1": { "channel": "copilot", "variants": [ { "file": "Copilot/v1.m4a" } ] },
    "ambience.cabin": { "channel": "ambience", "loops": true, "variants": [ { "file": "SFX/cabin.m4a" } ] }
  },
  "disclaimer": "…",
  "credits": "…"
}
```

* **Cue keys:** `pa.*` (see `Resources/Shared/event_map.json`), `copilot.<callout id>` (see `aircraft_profiles.json`), `sfx.chime`, `sfx.double_chime`, `sfx.seatbelt`, `sfx.engine_start`, `ambience.cabin`.
* **Resolution order:** a recorded variant in the selected language (weighted random) → the variant's `text` spoken by the system voice → the shared script for that language → the generic pack (SFX/ambience only) → reported as missing in the Live timeline.
* **Formats:** anything AVAudioFile reads (m4a/AAC, wav, caf, mp3). Audio is resampled to 44.1 kHz stereo.
* **Placeholders** in texts: `{airline}`, `{flightNumber}`, `{origin}`, `{destination}`, `{captain}`, `{cruiseAltitude}`, `{flightTimeHours}`, `{flightTimeMinutes}`. Wrap optional parts in `[ … ]`; a segment is dropped if any placeholder inside it is empty.

## Changing timing

`Resources/Shared/event_map.json` maps events to cues: `on` (e.g. `phase.CRUISE`, `event.altitude.descent.10000`, `event.goAround`), `delay`, `validPhases`, `priority`, `cooldown`, `repeatable`, `category`, `enabledByDefault`, `maxLatency`.
