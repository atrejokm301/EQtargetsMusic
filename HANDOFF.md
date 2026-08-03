# HANDOFF — EQtargets (macOS + iOS)

**Purpose:** Pick up work in Antigravity / any other agent with full context.  
**Last updated:** 2026-07-29  
**Machine user:** Kevin (`amed301`) · Apple team `RV23UF9649` (Personal Team) · device “Kevin’s Ayfon 17 PM” (iPhone 17 Pro Max)

---

## 1. What this product is

**EQtargets** = dual-layer parametric EQ brand:

| Layer | Role |
|--------|------|
| **Target** | AutoEQ / Squiglink compensation curve (10 peak bands + preamp) |
| **Fine-Tune** | Personal adjustment **on top** of Target (never overwrites Target) |

**Signal chain (both apps conceptually):**  
`audio → Target PEQ → Fine-Tune PEQ → output`

---

## 2. Two codebases (do not mix them)

| App | Path | Platform | Job |
|-----|------|----------|-----|
| **EQtargets (desktop)** | `/Users/amed301/ParametricEQ` | **macOS** | System-wide EQ via Core Audio **CATap** + dual EQ UI |
| **EQtargets Music** | `/Users/amed301/EQtargetsMusic` | **iOS** | Local music player + dual EQ (**in-app only**) |

Product display names:

- macOS: **EQtargets** (`PRODUCT_NAME = EQtargets`, bundle `com.eqtargets.app`)
- iOS: **EQtargets Music** (bundle `com.eqtargets.music`)

Xcode projects still use folder names `ParametricEQ` / `EQtargetsMusic` for historical reasons.

---

## 3. Critical product constraints (do not “fix” by ignoring)

### System-wide EQ on iOS
**Impossible** for third-party App Store apps. Cannot EQ YouTube, Apple Music, Netflix, Amazon Music, etc.

iOS app must only equalize **playback inside EQtargets Music**. UI already has a banner explaining this.

### System-wide EQ on macOS
**Possible** via **CATap** (macOS 14.2+): process tap → aggregate → ring buffer → AVAudioEngine (Target EQ → Fine-Tune EQ → default output).

Needs: **Screen & System Audio Recording** permission.

### Library scan on iOS
Cannot scan the whole phone. Only:

- App sandbox `Documents/Music/`
- User-imported files/folders (Files picker)

---

## 4. iOS app — current state (most recent work)

### Location
```
/Users/amed301/EQtargetsMusic/
├── AGENTS.md                 # Grok Dev team pipeline hooks
├── README.md
├── HANDOFF.md                # this file
├── EQtargetsMusic.xcodeproj
└── EQtargetsMusic/
    ├── App/EQtargetsMusicApp.swift
    ├── Models/{EQModels,Track}.swift
    ├── Services/{AudioPlayerEngine,LibraryStore}.swift
    ├── Theme/GrokTheme.swift
    ├── Views/
    │   ├── Root/RootTabView.swift
    │   ├── NowPlaying/NowPlayingView.swift
    │   ├── Library/MusicLibraryViews.swift
    │   ├── EQ/{EQGraphView,EQControlsView}.swift
    │   └── Components/TrackRowView.swift
    ├── Assets.xcassets
    └── Info.plist
```

### Features implemented & recent updates
- **Navigation & Shell:** Bottom dock: **Now Playing · Music · Artists · Albums · Search**.
- **Top Bar Hamburger Menu (`line.3.horizontal`):** Sleek leading navigation button on all tabs opening a unified **App Settings & DJ Controls** sheet.
- **Accent Color Themes:** Blue, Green, Red, Orange accent themes selectable via Hamburger Menu.
- **AutoMix & Custom DJ Crossfade System (Neutron Music Player Style):**
  - **Dual-Node Engine:** Dual player nodes (`playerA`, `playerB`) and mixers (`mixerA`, `mixerB`) feeding into Target + Fine-Tune 20-band PEQ DSP chain.
  - **Simultaneous Overlapping Playback:** Incoming and outgoing tracks play concurrently over `crossfadeDuration` seconds with equal-power cos/sin curve ($V_A = \cos(\text{progress} \cdot \frac{\pi}{2})$, $V_B = \sin(\text{progress} \cdot \frac{\pi}{2})$). Zero volume dips, zero gaps.
  - **Custom Intro Trim (Start Next Song At):** Configurable slider (`0:00` to `3:00` / 0–180s) skips intro silence/talking/applause on incoming tracks.
  - **Custom Outro Trim (Finish Current Song Early):** Configurable slider (`0:00` to `3:00` / 0–180s) finishes outgoing tracks early to skip trailing chatter/applause/silence.
  - **Auto-Persisted:** Settings saved in `UserDefaults`.
- **Album Track Number Ordering:** Tracks inside albums are strictly ordered by `discNumber` → `trackNumber` (1, 2, 3, 4...). `ArtistGroup.albums` is stored (not computed), eliminating SwiftUI identity invalidation and list flickering.
- **AirPods Max 2 Media Remote Fixes:** Explicit `.isEnabled = true` and active session assertion (`try? AVAudioSession.sharedInstance().setActive(true)`) for Digital Crown, noise control button, and hardware play/pause/skip commands.
- **Banger Shuffle & Repeat Modes:**
  - `Banger Shuffle` prioritizes high-BPM (≥ 115 BPM) tracks.
  - Repeat modes: `Off`, `Repeat All`, `Repeat One`.
- **Dual-Layer EQ & Profiles:**
  - Binary liquid glass toggle switch for Target vs Fine-Tune layer selection.
  - Dedicated **Save Target** and **Save Fine-Tune** profile modals.
  - AutoEQ `.txt` file importer automatically extracts file name and defaults target preset to "Target PQ".
- **Dual-Direction Swipe-to-Delete:** Both left-to-right (`.leading`) and right-to-left (`.trailing`) swipe actions on Songs, Albums, and Artists.
- **Liquid Glass Aesthetics:** True pitch-black (`#000000`) dark mode, transparent navigation headers without hairline separator lines (`shadowColor = .clear`), 10% softer borders and card strokes.
- **Sub-50ms Cold Launches:** Non-blocking asynchronous catalog loading (`Task.detached`), `dyld4` symbol stripping (`DEPLOYMENT_POSTPROCESSING = YES`, `STRIP_INSTALLED_PRODUCT = YES`).

### Performance & Build Optimization Stack
- **Full Fat LTO:** `LLVM_LTO = YES` (Monolithic whole-binary link-time optimization).
- **Whole Module Optimization:** `SWIFT_COMPILATION_MODE = wholemodule`.
- **Optimization Flags:** Swift `-O` speed (`SWIFT_OPTIMIZATION_LEVEL = -O`), Clang `-O3` (`GCC_OPTIMIZATION_LEVEL = 3`), `DEAD_CODE_STRIPPING = YES`.
- **Audio Processing Cap:** Max 44.1 kHz / 48 kHz sample rate, 50ms buffer duration (`setPreferredIOBufferDuration(0.05)`), 4Hz progress timer (suspended in background).

---

## 5. How to build & deploy iOS

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/amed301/EQtargetsMusic

# Release build for device (Kevin’s Ayfon 17 PM)
# Device UDID: 00008150-001148D40ED9401C
xcodebuild -project /Users/amed301/EQtargetsMusic/EQtargetsMusic.xcodeproj \
  -scheme EQtargetsMusic -configuration Release \
  -destination 'id=00008150-001148D40ED9401C' build

# Install and Launch on device
xcrun devicectl device install app --device 00008150-001148D40ED9401C \
  /Users/amed301/Library/Developer/Xcode/DerivedData/EQtargetsMusic-gtwmmssfmwcbopdgwpeisntapyhv/Build/Products/Release-iphoneos/EQtargetsMusic.app

xcrun devicectl device process launch --device 00008150-001148D40ED9401C \
  com.eqtargets.music
```

**Signing:** Personal Team `RV23UF9649` · identity `Apple Development: aktrejo301@gmail.com (486FU633BJ)`.

---

## 6. macOS app — current state

### Location
```
/Users/amed301/ParametricEQ/
├── ParametricEQ.xcodeproj   # scheme still named ParametricEQ; product EQtargets.app
├── README.md
└── ParametricEQ/
    ├── ParametricEQApp.swift, ContentView.swift
    ├── Models/{EQBand,EQProfile,AutoEQParser}.swift
    ├── Services/
    │   ├── EQEngine.swift              # DualEQState hub
    │   ├── SystemWideAudioEngine.swift # CATap pipeline
    │   ├── AudioRingBuffer.swift       # lock-free SPSC + prefill + underrun fade
    │   ├── FrequencyResponse.swift
    │   ├── ProfileStore.swift          # ~/Library/Application Support/EQtargets/
    │   ├── AudioDeviceService.swift
    │   └── PlaybackInfoService.swift
    ├── Theme/{AppTheme,GlassStyle}.swift
    ├── Views/{FrequencyResponseGraph,LayerSwitcherView,BandControlView,...}
    └── Resources/Branding/             # dark/light logos
```

---

## 7. What NOT to do

- Do not promise or implement iOS system-wide EQ for other apps
- Do not call `AVAudioPlayerNode.reset()` or disconnect graph while `AVAudioEngine` is running
- Do not store full-resolution album art for every track in `library_catalog.json`
- Do not make `ArtistGroup.albums` a computed property (causes list flickering)
- Do not remove `LLVM_LTO = YES` or `-O3` / `-O` optimization flags
- Do not set `xcode-select` away from full Xcode when building:  
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

---

## 8. One-liner for the next model

> Continue **EQtargets**: dual Target+Fine-Tune PEQ. **macOS** = system-wide CATap at `~/ParametricEQ` (product EQtargets.app). **iOS** = local player only at `~/EQtargetsMusic` (com.eqtargets.music); no system-wide on iOS. Recent iOS features: Neutron-style dual-node overlapping crossfade + custom Intro/Outro trims, top bar Hamburger Menu with accent themes & DJ controls, AirPods Max 2 media controls fix, stable track number album sorting, Full Fat LTO (`LLVM_LTO = YES`), `-O3` + `-O` speed optimization stack, true black liquid glass UI. Device deploy with team `RV23UF9649`. See this HANDOFF.md for full details.
