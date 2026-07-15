# App Store Connect — submission reference (Salish Tides)

Copy-paste values and a step-by-step for creating the App Store Connect (ASC)
record and the 1.0 submission. Fill the `⟨…⟩` placeholders. Assumes **Individual**
enrollment in the Apple Developer Program.

> Nothing here is code; this is a working checklist. Bundle id: `com.bguenther.salishtides`.

---

## 0. Prerequisite — register the Bundle ID first

The ASC "New App" form only lets you pick a Bundle ID that already exists in the
Developer portal. Two ways to create it:

- **Easiest:** after enrollment, open Xcode → Settings → Accounts → add your Apple
  ID, put your Team ID in `Config/Secrets.xcconfig`, then **archive to a device
  once** with automatic signing. Xcode registers `com.bguenther.salishtides` for
  you, and it appears in the ASC dropdown.
- **Manual:** developer.apple.com → Certificates, Identifiers & Profiles →
  **Identifiers → +** → App IDs → App → description "Salish Tides", Bundle ID
  (explicit) `com.bguenther.salishtides`. Capabilities: none needed (no push,
  no iCloud, no sign-in).

---

## 1. Create the app record

App Store Connect → **My Apps → + → New App**

| Field | Value |
|---|---|
| Platform | **iOS** |
| Name | **Salish Tides** — must be globally unique on the App Store (≤ 30 chars). If taken, fallbacks: "Salish Tides — Currents", "Salish Sea Tides". |
| Primary language | **English (U.S.)** |
| Bundle ID | `com.bguenther.salishtides` |
| SKU | `salishtides-ios-001` (internal only, never shown) |
| User access | **Full Access** |

---

## 2. Accept agreements (one-time)

ASC → **Business / Agreements, Tax, and Banking** → accept the **Free Apps**
agreement. No tax or banking forms are needed for a free app.

---

## 3. App information (metadata)

| Field | Value |
|---|---|
| Subtitle (≤ 30 chars) | `Salish Sea tides & currents` |
| Primary category | **Weather** *(recommended — see note)* |
| Secondary category | **Navigation** *(optional)* |
| Promotional text (≤ 170, editable anytime) | `Offline tide heights and tidal-current predictions for the Salish Sea.` |

**Category note:** the app carries a "**not** an official source for navigation"
disclaimer, so **Weather** (or Travel/Reference) is the lower-risk primary and
still fits tides/currents. **Navigation** is more discoverable but invites closer
review of the disclaimer — it's a defensible choice too. Pick one; this is a
product call.

---

## 4. Privacy — must match `PrivacyInfo.xcprivacy`

- **App Privacy → Data Collection:** answer **"No, we do not collect data from
  this app."** The app transmits nothing off-device; location is used on-device
  only. This is consistent with the shipped privacy manifest.
- **Privacy Policy URL:** ⟨REQUIRED — must host one, even with no data collected⟩.
  A one-page policy is enough (see draft offer at bottom). Can be a GitHub Pages
  page or gist.

---

## 5. Age rating

Answer the questionnaire with **all "None."** Result: **4+**.

---

## 6. Version 1.0 page (per-platform)

| Field | Value |
|---|---|
| Description (≤ 4000) | *draft below* |
| Keywords (≤ 100, comma-separated, no spaces after commas) | `tides,tide,current,currents,salish,puget sound,marine,boating,sailing,kayak` |
| Support URL | ⟨REQUIRED — e.g. the GitHub repo page or a simple contact page⟩ |
| Marketing URL | ⟨optional⟩ |
| Copyright | `2026 Bryan Guenther` |
| What's New | (1.0 initial release — leave blank or "Initial release") |

### Draft description
```
Salish Tides is a fast, fully offline planning aid for tides and tidal currents
across the Salish Sea (British Columbia and Washington).

• Tidal-current vectors from the four-volume Salish Sea Tidal Current Atlas
• Tide-height predictions from NOAA CO-OPS (US) and CHS IWLS (Canada)
• Animated current visualization on an offline nautical basemap
• Works with no signal — everything is bundled on-device

Salish Tides is a planning aid, not an official source for navigation. Always
consult official charts and current tables.
```

### Screenshots — REQUIRED, both device families (app is universal, iPhone + iPad)
Upload at least one each (up to 10):
- **iPhone 6.9"** display (e.g. iPhone 16 Pro Max) — 1290 × 2796 px
- **iPad 13"** display (e.g. iPad Pro 13" M4) — 2064 × 2752 px

Capture from the simulator: run the app, `Device → Trigger Screenshot` (or
`⌘S`), on both an iPhone 6.9" and iPad 13" simulator.

---

## 7. App Review information

| Field | Value |
|---|---|
| Sign-in required? | **No** (no account/login in the app) |
| Contact | ⟨your name / phone / email⟩ |
| Notes for reviewer | See below |

### Reviewer notes
```
Salish Tides is a fully offline tide- and tidal-current planning aid for the
Salish Sea. No account or login is required; all data is bundled on-device.

Location: the app requests When-In-Use location only to show the user's position
on the chart. Location is never stored or transmitted. Tapping the location
button in the map controls triggers the prompt.

The app displays a "not for navigation" disclaimer and full data-source
attribution under Settings → Data Sources.
```

---

## 8. Export compliance

Already handled in-app: `ITSAppUsesNonExemptEncryption = false` is set in
Info.plist (app uses only standard HTTPS), so ASC will **not** prompt for export
compliance on each build.

---

## 9. Build upload → TestFlight → submit

1. In Xcode: **Product → Archive** (a real device / "Any iOS Device", not a
   simulator). Requires `data/` bootstrap present and the Team ID set.
2. **Organizer → Distribute App → App Store Connect → Upload.**
3. Wait for processing (minutes), then the build shows under **TestFlight**.
   Add internal testers (up to 100, no review) to test immediately; external
   testers require a brief Beta App Review.
4. When ready for the store: attach the build to the **1.0** version, complete
   any remaining metadata, and **Submit for Review**.

---

## Open items needing your input
- [ ] Confirm the app **Name** is available on the App Store (and pick a fallback).
- [ ] Decide **primary category** (Weather vs Navigation).
- [ ] Provide a **Privacy Policy URL** and **Support URL** (I can draft the policy).
- [ ] Reviewer **contact** details.
- [ ] Capture **screenshots** (iPhone 6.9" + iPad 13").
