# App Store submission checklist — Salish Tides

Living checklist for the 1.0 App Store release. Facts pulled from the repo are
filled in; `[ ]` items are actions you take in App Store Connect / Xcode.

## Identity (from the project)
- **Bundle ID:** `com.bguenther.salishtides`
- **Version / build:** `1.0` (`1`) — bump `CURRENT_PROJECT_VERSION` in
  `Config/Base.xcconfig` for every new TestFlight/App Store upload.
- **Deployment target:** iOS 17.0 · iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`)
- **Display name:** Salish Tides

## Brand assets — DONE (this branch)
- [x] App icon — emblem, black-on-white, with automatic dark variant
      (`AppIcon.appiconset`, Any + Dark appearances, 1024², no alpha)
- [x] Launch screen — wordmark centered on adaptive white/black background
      (`UILaunchScreen → LaunchLogo`, light/dark variants)
- [x] Regenerate anytime from `docs/logo.png`:
      `python3 dev/brand/make_brand_assets.py`

## Screenshots — REQUIRED (captured from simulators)
App Store Connect accepts one iPhone set + one iPad set that cover all sizes:
- [ ] **iPhone 6.9"** — iPhone 17 Pro Max — 1320 × 2868 px, 1–10 images
- [ ] **iPad 13"** — iPad Pro 13" (M4) — 2064 × 2752 px, 1–10 images
- Suggested shots (3–5): live current map, tide chart / phase panel,
  date-picker scrubbing, a strong-current zoom, offline state.
- No status-bar/marketing overlays required; clean device frames are fine.

## App Store Connect — metadata you enter
- [ ] **Name:** Salish Tides (30 char max)
- [ ] **Subtitle:** e.g. "Offline currents for the Salish Sea" (30 char max)
- [ ] **Category:** Navigation (primary); Weather (secondary, optional)
- [ ] **Description:** long form — what it does, offline-first, SalishSeaCast
      live model + on-device harmonic fallback, planning-aid disclaimer.
- [ ] **Keywords:** tides, currents, Salish Sea, kayak, boating, sailing,
      slack, ebb, flood, marine (100 char total, comma-separated)
- [ ] **Promotional text** (optional, 170 char, editable without review)
- [ ] **Support URL:** https://salishtides.app  (or a contact page)
- [ ] **Marketing URL** (optional): https://salishtides.app
- [ ] **Copyright:** 2026 Bryan Guenther
- [ ] **Age rating:** 4+ (no objectionable content)

## Privacy — mostly settled in the repo
- [x] Privacy manifest present (`PrivacyInfo.xcprivacy`): no tracking, **no data
      collected** (location is used on-device only, never transmitted).
- [ ] **App Privacy** questionnaire in ASC → answer **Data Not Collected**.
- [ ] **Privacy Policy URL:** https://salishtides.app/privacy
      (served from `docs/privacy.html`).

## Build & submit
- [x] **Export compliance:** `ITSAppUsesNonExemptEncryption = false` already set
      (standard HTTPS only) — no per-upload prompt.
- [ ] Archive a **Release** build (real device / generic iOS device), upload via
      Xcode Organizer or `xcodebuild -exportArchive`.
- [ ] Confirm `MAPTILER_KEY` is present in the Release build's config.
- [ ] TestFlight: install once, sanity-check icon + launch + map on device.
- [ ] Attach the build to the 1.0 App Store version, add screenshots + metadata.
- [ ] **App Review notes:** mention it's a planning aid, not for navigation;
      no login required; works offline with bundled data.
- [ ] Submit for review.

## Not blocking 1.0 (nice to have later)
- Tinted (monochrome) home-screen icon variant — iOS auto-generates one from the
  dark icon if omitted; add a hand-tuned grayscale later if desired.
- Localized metadata / screenshots for other App Store regions.
