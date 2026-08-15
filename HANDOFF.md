# HANDOFF — EQtargets Music (iOS) + product map

**Purpose:** Pick up work in Grok / any agent with full context.  
**Last updated:** 2026-08-10  
**Git:** branch `EQtargetsbeta` @ `47c4a09` (pushed to `origin/EQtargetsbeta`)  
**Machine user:** Kevin (`amed301`) · Apple team `RV23UF9649` (Personal Team) · device “Kevin’s Ayfon 17 PM” (iPhone 17 Pro Max, UDID `00008150-001148D40ED9401C` / CoreDevice `35F96986-E00F-5B52-94C1-659989BC4781`)

**Also mirror when changing product-wide facts:** `/Users/amed301/Desktop/EQtargets-HANDOFF.md` (macOS + iOS map) if that file still exists.

**Grok skills pipeline workspace:** `/Users/amed301/Downloads/grok-dev-team-2` (AGENTS.md + eight skills). Product code is **not** there — it is only in `~/EQtargetsMusic`.

---

## 1. What this product is

**EQtargets** = dual-layer parametric EQ brand:

| Layer | Role |
|--------|------|
| **Target** | AutoEQ / Squiglink compensation (10 peak/shelf bands + preamp) |
| **Fine-Tune** | Personal tweak **on top** of Target (never overwrites Target) |
| **Bass Style** | Independent post-PEQ stage (never mutates Target / Fine-Tune) |

**Signal chain (current):**

```
Player → Target PEQ → Fine-Tune PEQ → Bass Processor → deck mixer → main mixer → output
```

Bass styles: None · Transient Punch · Sustain/Rumble · Natural Clean  
Controls: Strength / Cutoff / Post gain (+ recommended Hz per style in UI).  
State: `BassProcessorState` on `AudioPlayerEngine.bass` (UserDefaults key `eqtargets.bassProcessor`).  
UI: `BassStyleControlsView` under EQ on Now Playing (compact chips).

---

## 2. Two codebases (do not mix)

| App | Path | Platform | Job |
|-----|------|----------|-----|
| **EQtargets** | `/Users/amed301/ParametricEQ` | **macOS** | System-wide EQ (Process Tap / CATap primary) |
| **EQtargets Music** | `/Users/amed301/EQtargetsMusic` | **iOS** | Local player + dual EQ (**in-app only**) |

| | iOS | macOS |
|--|-----|-------|
| Product name | EQtargets Music | EQtargets |
| Bundle | `com.eqtargets.music` | `com.eqtargets.app` |
| Xcode folder | `EQtargetsMusic` | `ParametricEQ` |

---

## 3. Critical constraints (do not “fix” by ignoring)

- **No system-wide EQ on iOS** (App Store). Only in-app playback.
- **Library** = sandbox `Documents/Music/` + user imports only.
- **Never** call `AVAudioPlayerNode.reset()` / disconnect graph while `AVAudioEngine` is running carelessly.
- **AirPods / BT (macOS):** do not open duplex (mic+out) — HFP kills music.
- Prefer: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **Never touch without asking (AGENTS):** Auth / Payments / DB migrations (N/A on this app mostly).
- **Personal Team:** free profiles expire ~7 days. Re-sign after Xcode Accounts sign-in if install fails with `0xe8008011`.
- **Honest fixes only:** Kevin rejects event-level “fixed” claims. Verify with build + device behavior.

---

## 4. iOS — location & tree (current)

```
/Users/amed301/EQtargetsMusic/
├── AGENTS.md
├── README.md
├── HANDOFF.md                 # THIS FILE
├── EQtargetsMusic.xcodeproj
├── build-release/             # last Release product (local; untracked)
├── build-device/               # Debug device builds (local; untracked)
├── logs/                      # console / crash captures
└── EQtargetsMusic/
    ├── App/EQtargetsMusicApp.swift
    ├── Info.plist
    ├── Models/
    │   ├── EQModels.swift         # PEQ bands, shelves, FR curves, DualEQState
    │   ├── BassProcessor.swift    # post stage models + DSP helpers
    │   └── Track.swift            # bookmarks, SecurityScopedAccess, metadata
    ├── Services/
    │   ├── AudioPlayerEngine.swift    # dual deck, remote, crossfade, bass chain, power
    │   ├── CrossfadeEngine.swift      # settings + plan math + abortWinner
    │   ├── SilenceAnalyzer.swift
    │   ├── LibraryStore.swift         # catalog, BPM, album order repair
    │   ├── ArtworkImageCache.swift    # list thumbs + hero cache (shared max side)
    │   ├── SmartShuffleSelector.swift
    │   ├── TempoFeel.swift, BPMDetector.swift, …
    │   └── PerformanceMemory.swift
    ├── Theme/{AppSurfaceColors,GrokTheme,AppTypography}.swift
    └── Views/
        ├── Root/RootTabView.swift     # transitionProgress, mini/full morph, tabs
        ├── NowPlaying/NowPlayingView.swift
        ├── Player/
        │   ├── ImmersivePlayerView.swift   # full player + hero morph
        │   ├── MiniPlayerBar.swift
        │   ├── PlayerArtworkVisualCache.swift
        │   └── QueueSheet, scrubber, surface state, …
        ├── Library/MusicLibraryViews.swift
        ├── EQ/{EQGraphView,EQControlsView}.swift
        └── Components/TrackRowView.swift
```

---

## 5. Git / branch state (2026-08-10)

| Item | Value |
|------|--------|
| Active branch | **`EQtargetsbeta`** |
| HEAD | **`47c4a09`** — *Beta: sharp mini→full art, album track order, EQ graph polish.* |
| Previous beta | `153c6f7` — Bass Style post-PEQ, shelf filters, dual-deck EQ safety |
| Remote | `origin` → `https://github.com/atrejokm301/EQtargetsMusic.git` |
| `main` | `7b78c73` (older; beta is ahead for product work) |
| Working tree | Clean after `47c4a09` push (as of handoff write) |

**Push command:**

```bash
cd /Users/amed301/EQtargetsMusic
git push -u origin EQtargetsbeta
```

---

## 6. Recent session work (2026-08-09 → 2026-08-10) — shipped & verified

### 6.1 Dual-PEQ death mid-crossfade (real bug — fixed)

**Symptom:** Dual 10-band PEQ (Target + Fine-Tune) went silent after changing crossfade blend 30→45s until force-quit.

**Root cause:** Soft `cancelTransition` on duration change left the **incoming deck** as active without re-applying EQ. Battery path keeps inactive-deck Target/Fine **bypassed**, so after abort you heard a deck with EQ still bypassed.

**Fix (in `153c6f7` and earlier beta commits):**
1. Duration / curve / adaptiveBPM changes **do not abort** an in-flight fade — re-arm for the *next* blend only.
2. Soft abort commits via `CrossfadeMath.abortWinner` + deck swap + `applyEQ` / `reapplyDSP`.
3. Logging around cancel + mid-fade duration.

**Files:** `AudioPlayerEngine.swift`, `CrossfadeEngine.swift`.

### 6.2 Bass Style (independent)

- Post-PEQ only; **never** mutates Target / Fine-Tune / AutoEQ import.
- Strength / Cutoff / Post gain + style chips (compact UI).
- Model: `BassProcessor.swift` + engine chain wiring.

### 6.3 Low / High Shelf on parametric bands

- `EQFilterType`: peak / lowShelf / highShelf.
- Biquad RBJ in `EQModels` / engine application path.
- Graph + controls show shelves correctly.

### 6.4 Album track order

- Bug: album detail listed tracks A–Z (filename/title), not disc/track order.
- Fix: restore **disc → track number → filename** sort; catalog repair path in `LibraryStore` when numbers missing / wrong; avoid nil-ing track numbers incorrectly.
- **Do not** reintroduce pure title sort for albums.

### 6.5 UI polish

- **Hamburger:** 44pt hit target (GrokTheme); mini-player full-screen hit plate was blocking menu — bottom-aligned frame only.
- **Target pill while on Fine-Tune:** nested Binding bug — assign whole `DualEQState` via `selectEditingLayer` (not nested field bindings that fight).

### 6.6 Frequency response graph

- Premium / high-tech look with **low battery cost** (cached curves, avoid per-frame heavy work).
- `EQGraphView.swift` + `FrequencyResponse` helpers in `EQModels`.

### 6.7 Mini → full player artwork soft during slow pull (**fixed & device-confirmed**)

**Symptom:** Slowly pulling mini player → full player showed low-quality album art during the morph.

**Root cause:**
- Catalog `artworkData` is ~**96px JPEG** list thumb.
- Immersive hero only loaded high-res when progress ≥ **~0.88** and **not** interactively dragging → slow drag never upgraded.

**Fix (`47c4a09`):**
- Warm high-res on overlay appear + track change (overlay stays mounted while a track exists).
- Load on expand start (`isExternalDragging` / progress ≥ 0.02), not only settle.
- Shared `ArtworkImageCache.playerHeroMaxPointSide = 512` with Lock Screen / Now Playing so one decode serves both.
- Sync `cachedHero(trackID:)` so expand can paint sharp art immediately if already decoded.
- `heroIsHighRes` flag + generation token to avoid thumb clobber / stale task races.

**Files:** `ArtworkImageCache.swift`, `ImmersivePlayerView.swift`, `AudioPlayerEngine.swift` (NP art max side).  
**Verified:** Kevin on device — working.

### 6.8 Ops / residual (honest, not “fully fixed”)

| Item | Status |
|------|--------|
| Free-team profile expiry (`0xe8008011`) | Expected ~7 days; re-sign after Xcode login |
| AVAudioSession Hang Risk | Reduced via forceActive + prefs-only when values change; **not zero** on cold start |
| Sandbox extension 22 noise | Reduced via NSHomeDirectory container skip for some paths; residual possible |
| Hang / session spam | Prefer not to thrash activate/deactivate every UI tick |

---

## 7. Recommended user setup (alabanzas / júbilo test)

| Control | Value |
|---------|--------|
| Blend length | **30s** (try 25–40; changing mid-fade no longer kills EQ) |
| Curve | **Equal Power** |
| Skip intros | **ON** |
| Smart tempo blend | **OFF** for exact length |
| Smart Tempo Up Next | optional |
| Bass Style | optional (does not touch Target/Fine-Tune) |
| Best test | Let songs **end naturally** (not late Next) |

---

## 8. Build & deploy

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/amed301/EQtargetsMusic

# Debug → device (typical Grok loop)
xcodebuild -scheme EQtargetsMusic \
  -destination 'platform=iOS,id=35F96986-E00F-5B52-94C1-659989BC4781' \
  -derivedDataPath build-device \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=RV23UF9649 \
  build

APP=build-device/Build/Products/Debug-iphoneos/EQtargetsMusic.app
xcrun devicectl device install app --device 35F96986-E00F-5B52-94C1-659989BC4781 "$APP"
xcrun devicectl device process launch --device 35F96986-E00F-5B52-94C1-659989BC4781 com.eqtargets.music

# Release (preferred for Kevin day-to-day)
xcodebuild -scheme EQtargetsMusic -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-release \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=RV23UF9649 \
  build
```

**List devices:**

```bash
xcrun devicectl list devices
```

**Signing:** Personal Team `RV23UF9649` · `Apple Development: aktrejo301@gmail.com`  
Device must show **available (paired)** — unlock + trust if install fails.

**Logs:** `logs/` + `logs/collect-device-logs.sh` patterns used previously for console attach.

---

## 9. Architecture notes (playback)

- **Dual deck:** each deck = Player → Target EQ → Fine EQ → **Bass** → deck mixer → main mixer.
- Crossfade = **mixer volumes only** (equal-power / smooth / linear); both decks play during fade.
- Inactive deck EQ bypassed when not crossfading (battery) — **must reapply on abort/promote**.
- Natural end: `armCrossfadeWatch` / `fireCrossfadeIfNeeded` when remaining ≤ plan.effective.
- Now Playing: `MPRemoteCommandCenter` play/pause/next/prev/seek; **shuffle remote off**.
- Session restore: queue + position (`playbackSession` + position sidecar).
- **Artwork:** list rows = catalog thumb; full player + NP = `ArtworkImageCache.heroImage` from file (max 512 pt).

---

## 10. What NOT to do

- Promise iOS system-wide EQ.
- Reintroduce “Start next song at” file cue without Kevin asking.
- Hard-tier Smart Tempo that collapses to sameTight pool.
- Pure cool navy / pure white slabs for app chrome (warm surfaces); keep **immersive** OLED black.
- Warm-shift EQ analysis graph colors.
- Run offline BPM while user is playing (thermal) — pause analysis during playback.
- Force CADisplayLink on library lists for “smooth scroll.”
- Claim Dual-EQ / crossfade “fixed” without a mid-fade duration change + natural-end device test.
- Gate full-player high-res art on settle-only / non-dragging progress thresholds (re-breaks soft expand art).
- Sort album tracks alphabetically by title for “cleanup.”

---

## 11. Suggested next work

1. Optional: Release config install for day-to-day (Debug is what last Grok loop used).
2. Optional: if first expand on a brand-new track still flashes thumb for one frame, further prewarm hero at queue-next (NP already loads 512 — usually enough).
3. Optional: surface effective crossfade seconds in UI when adaptive/short-song caps apply.
4. Optional: Quality / Balanced / Battery user toggle (quality path already default when cool).
5. Optional: macOS Process Tap routing — **separate** repo `~/ParametricEQ` + Desktop handoff.
6. Keep beta branch as ship lane until Kevin asks to merge `EQtargetsbeta` → `main`.

---

## 12. One-liner for the next model

> **EQtargets Music** iOS at `~/EQtargetsMusic`, branch **`EQtargetsbeta` @ `47c4a09`**: dual-deck **Target → Fine-Tune → Bass**; crossfade = blend length (do not soft-cancel mid-fade without `abortWinner` + `applyEQ`); catalog art is **96px** — full player hero must load **early** (shared 512pt cache with Lock Screen); album order = disc/track; free team `RV23UF9649` 7-day profiles; install via `devicectl` CoreDevice `35F96986-…` bundle `com.eqtargets.music`. Skills pipeline lives in `~/Downloads/grok-dev-team-2`. macOS system EQ is **`~/ParametricEQ`** — do not mix.

---

## 13. Session continuity tips

- Prefer **reading code in `~/EQtargetsMusic`** over this file when behavior is ambiguous; handoff can lag.
- After audio graph / EQ / crossfade edits: natural-end + mid-fade settings change + skip/next under dual EQ on **device**.
- After UI morph / art edits: slow mini→full pull on a track that has embedded cover art.
- Console: `logs/` and prior `live-console-*.txt` / `verify-*.txt` patterns.

---

*End of handoff. Prefer small testable deploys after audio/routing/theme changes. When in doubt, ask Kevin.*
