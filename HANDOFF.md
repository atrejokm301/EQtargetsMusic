# HANDOFF — EQtargets Music (iOS) + product map

**Purpose:** Pick up work in Grok / Antigravity / any agent with full context.  
**Last updated:** 2026-08-05  
**Machine user:** Kevin (`amed301`) · Apple team `RV23UF9649` (Personal Team) · device “Kevin’s Ayfon 17 PM” (iPhone 17 Pro Max, UDID `00008150-001148D40ED9401C` / CoreDevice `35F96986-E00F-5B52-94C1-659989BC4781`)

**Also mirror when changing product-wide facts:** `/Users/amed301/Desktop/EQtargets-HANDOFF.md` (macOS + iOS map)

---

## 1. What this product is

**EQtargets** = dual-layer parametric EQ brand:

| Layer | Role |
|--------|------|
| **Target** | AutoEQ / Squiglink compensation (10 peak bands + preamp) |
| **Fine-Tune** | Personal tweak **on top** of Target (never overwrites Target) |

**Signal chain:** `audio → Target PEQ → Fine-Tune PEQ → output`

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

**Grok Dev skills / AGENTS pipeline:** `/Users/amed301/Downloads/grok-dev-team`

---

## 3. Critical constraints (do not “fix” by ignoring)

- **No system-wide EQ on iOS** (App Store). Only in-app playback.
- **Library** = sandbox `Documents/Music/` + user imports only.
- **Never** call `AVAudioPlayerNode.reset()` / disconnect graph while `AVAudioEngine` is running carelessly.
- **AirPods / BT:** do not open duplex (mic+out) on desktop path — HFP kills music (macOS).
- Prefer: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

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
└── EQtargetsMusic/
    ├── App/EQtargetsMusicApp.swift
    ├── Info.plist             # UIWhitePointAdaptivityStylePhoto, fonts, audio bg
    ├── Models/{EQModels,Track}.swift
    ├── Services/
    │   ├── AudioPlayerEngine.swift    # dual deck, remote, crossfade, power
    │   ├── CrossfadeEngine.swift      # settings + plan math
    │   ├── SilenceAnalyzer.swift      # skip silence v3
    │   ├── LibraryStore.swift         # catalog + BPM batches
    │   ├── SmartShuffleSelector.swift # Smart Tempo Up Next v4
    │   ├── TempoFeel.swift            # lanes + mild clash scale
    │   ├── BPMDetector.swift, BangerShuffle.swift, …
    ├── Theme/
    │   ├── AppSurfaceColors.swift     # warm Light/Dark surfaces (NEW)
    │   ├── GrokTheme.swift
    │   └── AppTypography.swift
    ├── Views/
    │   ├── Root/RootTabView.swift
    │   ├── NowPlaying/NowPlayingView.swift   # AutoMixSettingsSheet
    │   ├── Player/{ImmersivePlayerView,MiniPlayerBar,QueueSheet,…}
    │   ├── Library/MusicLibraryViews.swift
    │   ├── EQ/{EQGraphView,EQControlsView}.swift
    │   └── Components/TrackRowView.swift
    └── Assets.xcassets
```

**Git note (as of handoff):** large uncommitted working tree (crossfade, silence, smart shuffle, theme, engine, …). `AppSurfaceColors.swift` was untracked until added to `project.pbxproj`. Prefer commit before next large feature.

---

## 5. Session work (2026-08-04 → 2026-08-05) — what shipped in code

### 5.1 Lock screen shuffle (reverted)
- Tried `MPRemoteCommandCenter.changeShuffleModeCommand` for system Now Playing shuffle.
- Kevin: **nvm / revert** — not kept. Shuffle remote explicitly disabled.

### 5.2 Crossfade / dual-deck (alabanza blend) — product model

**One slider controls both decks:**

| Setting (UI) | Code | Meaning |
|--------------|------|---------|
| **Blend length** 0–60s | `CrossfadeSettings.durationSeconds` | When current has ~N s left, start next deck; after N s next is **full**, current gone |
| **Skip intros / applause** | `skipSilence` | Auto trim intro/outro (live alabanzas) |
| **Equal Power / Smooth / Linear** | `curve` | Volume shape |
| **Smart tempo blend** | `adaptiveBPM` | Mild shorten only if tempos clash |

**Removed from product UX (still in model for Codable compat, ignored in playback):**
- **“Start next song at”** file cue (`incomingStartOffsetSeconds`) — Kevin did **not** want mid-file cue; he wanted blend length. Cue path forced to ignore offset; UI slider removed.

**Caps (CrossfadeMath):** leave ~4s body; **no** old 70% incoming cap (that crushed 35s → ~9–11s). Adaptive tempo floor ~0.82.

**Key files:** `CrossfadeEngine.swift`, `AudioPlayerEngine.beginCrossfadeV2`, `AutoMixSettingsSheet` in `NowPlayingView.swift`.

**Bugfix (beta — Dual 10-PEQ died after blend length change):** Changing crossfade
duration mid-fade used to call soft `cancelTransition` without promoting the incoming
deck. Battery path keeps `targetEQ`+`fineEQ` **bypassed** on the inactive deck, so the
track you were hearing lost AutoEQ until force-quit. Fix: (1) duration/curve/adaptiveBPM
no longer abort an in-flight fade — they re-arm for the *next* blend; (2) soft abort
commits via `CrossfadeMath.abortWinner` + deck swap + `applyEQ`; (3) EOF residual advance
if completion was invalidated.

### Bass Style (Wavelet-style post stage)
Signal chain is now:
`Player → Target PEQ → Fine-Tune PEQ → Bass Processor → Output`
Bass **never** mutates Target / Fine-Tune / AutoEQ import. State: `BassProcessorState`
on `AudioPlayerEngine.bass` (persisted `eqtargets.bassProcessor`). Styles: None,
Transient Punch, Sustain/Rumble, Natural Clean + strength / cutoff / post gain.
UI: `BassStyleControlsView` under EQ on Now Playing.

### 5.3 Skip silence v3
- `SilenceAnalyzer` deeper intro scan, better gate, energy onset, stronger outro.
- **Off = real Off:** full file, cache keyed by version, **reschedule active deck** on toggle.
- Toast: “Skip silence on/off”.

### 5.4 Smart Tempo Up Next v4
- Old v3 hard tiers (`sameTight` first) looped 2–3 songs.
- v4: wider mix pool, hard recent cooldown, session pick ring, record currently playing, hotter softmax.
- Offline BPM analysis **paused while `isPlaying`** (thermal) — does **not** disable Smart Tempo; only delays missing BPMs.

### 5.5 Battery / thermal / quality
- BPM: `LibraryStore.setPlaybackActive` from `RootTabView` on `isPlaying`.
- Session persist: position sidecar; full queue not every progress tick.
- Inactive deck EQ bypassed when not crossfading.
- Progress / Now Playing / silence refine thermal-aware.
- **Quality-first when cool:** ~50 ms IO buffer, session rate aligned to graph, Mastering SRC, native 44.1/48 when possible. Larger buffers only when hot / LPM / background.

### 5.6 Artwork palette
- BGRA red↔blue fix (DeviceRGB RGBA buffer).
- Center-weighted, drop white mats, chroma ranking.
- Keep full k-means quality; mild sat lift only.
- Immersive full player uses art atmosphere; **foundation stays `Color.black` (OLED)**.

### 5.7 Light mode text stuck white
- `.equatable()` lists ignored `isDark` → rows never repainted after light switch.
- Fix: pass `isDark` into list bodies + `TrackRowView`.
- Nav titles: dynamic warm labels.

### 5.8 Warm Light / Dark (not new themes)
- `AppSurfaceColors.swift` + `GrokTheme` surfaces.
- Light cream `#F8F4EC`; Dark warm charcoal **`#0A0908`** (Kevin OK — not greyish).
- **Immersive player:** pure OLED black (unchanged).
- EQ Target/Fine analysis tints **not** warm-shifted.
- `Info.plist`: `UIWhitePointAdaptivityStyle` = **Photo**.

### 5.9 DisplayLink / scroll
- Discussed CADisplayLink for lists — **not needed**; leave lists as-is.

---

## 6. Recommended user setup (alabanzas / júbilo test)

| Control | Value |
|---------|--------|
| Blend length | **30s** (try 25–40) |
| Curve | **Equal Power** |
| Skip intros | **ON** |
| Smart tempo blend | **OFF** for exact length |
| Smart Tempo Up Next | optional |
| Best test | Let songs **end naturally** (not late Next) |

---

## 7. Build & deploy

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/amed301/EQtargetsMusic

# Release (preferred for Kevin day-to-day)
xcodebuild -scheme EQtargetsMusic -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build-release \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=RV23UF9649 \
  build

APP=build-release/Build/Products/Release-iphoneos/EQtargetsMusic.app
xcrun devicectl device install app --device 35F96986-E00F-5B52-94C1-659989BC4781 "$APP"
xcrun devicectl device process launch --device 35F96986-E00F-5B52-94C1-659989BC4781 com.eqtargets.music
```

**Release flags (confirmed in project + last link line):**
- Swift **`-O`** + **wholemodule**
- Clang **`-O3`**
- **LLVM_LTO = YES**
- Dead strip + `strip -D`
- DEPLOYMENT_POSTPROCESSING / STRIP_INSTALLED_PRODUCT

**Signing:** Personal Team `RV23UF9649` · `Apple Development: aktrejo301@gmail.com`

**Last Release product size:** ~6 MB app package.

Device must show **available (paired)** — USB unlock if `unavailable` (Wi‑Fi alone often not enough).

---

## 8. Architecture notes (playback)

- **Dual deck:** each deck = Player → Target EQ → Fine EQ → deck mixer → main mixer.
- Crossfade = **mixer volumes only** (equal-power / smooth / linear); both decks play during fade.
- Natural end: `armCrossfadeWatch` / `fireCrossfadeIfNeeded` when remaining ≤ plan.effective.
- Now Playing: `MPRemoteCommandCenter` play/pause/next/prev/seek; **shuffle remote off**.
- Session restore: queue + position (`playbackSession` + position sidecar).

---

## 9. What NOT to do

- Promise iOS system-wide EQ.
- Reintroduce “Start next song at” file cue without Kevin asking (confused with blend length).
- Hard-tier Smart Tempo that collapses to sameTight pool.
- Pure `Color.white` / cool navy slabs for app chrome (use warm surfaces); keep **immersive** pure black.
- Warm-shift EQ analysis colors.
- Run offline BPM while user is playing (thermal).
- Force display link on library lists for “smooth scroll.”

---

## 10. Suggested next work

1. **Kevin test:** Release blend 30s + skip on + natural end on júbilo; confirm full volume at end.
2. **Git commit** the uncommitted engine/theme/crossfade stack (clean message).
3. Optional: macOS Process Tap routing (BlackHole Auto) — see Desktop handoff / ParametricEQ.
4. Optional: if short songs still toast-cap blends, surface effective seconds in UI always.
5. Optional: Quality / Balanced / Battery user toggle (quality path already default when cool).

---

## 11. One-liner for the next model

> **EQtargets Music** iOS at `~/EQtargetsMusic`: dual-deck **blend length** = when next starts and when it’s full (0–60s); **skip silence v3** real on/off; **no** file-cue “start next at”; Smart Tempo **v4** diversity; warm Light/Dark chrome + **OLED black immersive**; quality-first audio when cool; Release = `-O` / `-O3` / LTO. Team `RV23UF9649`. Device install via `devicectl` CoreDevice id `35F96986-…`. Commit pending. macOS system EQ is **separate** repo `~/ParametricEQ`.

---

*End of handoff. Prefer small testable deploys after audio/routing/theme changes. When in doubt, ask Kevin.*
