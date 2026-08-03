# EQtargets Music (iOS)

Local music player for iPhone with dual-deck equal-power **crossfade**, **silence-skip**, **Target + Fine-Tune** parametric EQ, AutoEQ import, Banger / Smart BPM queue selection, MiniPlayer + immersive full player, and frosted Queue sheet.

## Important: system-wide EQ?

**No.** Apple does not allow third-party apps to intercept YouTube, Apple Music, Spotify, Netflix, etc.

This app only equalizes **audio played inside EQtargets Music** (your imported files).

---

## Share / test package — open in Xcode & run

### What you need

1. A **Mac** with **Xcode 15+** (Xcode 16/26 is fine). Install from the Mac App Store if needed.
2. An **Apple ID** (free) for signing. Paid Developer Program is **not** required for personal device testing.
3. Optional: a physical **iPhone** (recommended) or use the **Simulator** (Simulator cannot easily import large libraries via Files the same way).

### 1. Unzip the project

1. Download the zip from your friend.
2. Double-click to unzip (or `unzip EQtargetsMusic-share.zip`).
3. You should see a folder containing:
   - `EQtargetsMusic.xcodeproj`
   - `EQtargetsMusic/` (source code)
   - `README.md` (this file)

**Tip:** Put the folder somewhere simple, e.g. `~/Desktop/EQtargetsMusic` or `~/Developer/EQtargetsMusic`.

### 2. Open in Xcode

**Option A (easiest)**  
Double-click `EQtargetsMusic.xcodeproj`.

**Option B (Terminal)**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
open /path/to/EQtargetsMusic/EQtargetsMusic.xcodeproj
```

If Xcode asks to **Trust** / download components, accept and wait for finishes.

### 3. Select the project & set Signing

1. In the left sidebar (Project navigator), click the blue **EQtargetsMusic** project icon.
2. Select the **EQtargetsMusic** target.
3. Open the **Signing & Capabilities** tab.
4. Check **Automatically manage signing**.
5. Under **Team**, pick **your Apple ID team**.
   - If the list is empty: **Xcode → Settings → Accounts → + → Apple ID**, then sign in and return here.
6. If Xcode shows a red signing error, change **Bundle Identifier** to something unique, e.g.  
   `com.yourname.eqtargetsmusic`  
   (must be unique on your machine / team).

### 4. Choose a run destination

Top toolbar, next to the Run button:

- **Simulator:** e.g. **iPhone 16** / **iPhone 17**
- **Real device:** unlock the iPhone, connect **USB** the first time (or use wireless after enabling **Connect via network** in Xcode → Window → Devices and Simulators)

### 5. Build & run

Press **⌘R** (Product → Run).

**First time on a physical iPhone:**

1. Trust the computer if prompted on the phone.
2. If the app won’t open: **Settings → General → VPN & Device Management** (or **Developer Mode**) → trust the developer certificate.
3. iOS 16+: enable **Developer Mode** if asked (Settings → Privacy & Security).

### 6. Import music to test

1. In the app, open the **Music** tab.
2. Tap **+** / **Import Audio** and pick files from Files / iCloud Drive.
3. Or use **Files** on the phone: **On My iPhone → EQtargets Music** (if file sharing is available) and drop audio there, then rescan if needed.

Supported formats depend on AVFoundation (MP3, M4A/AAC/ALAC, FLAC, WAV, AIFF, CAF, etc.).

### 7. Features worth testing

| Feature | Where |
|--------|--------|
| Play / pause / next | MiniPlayer bar + full player |
| Immersive full player | Tap MiniPlayer art/title or swipe up |
| Queue (Playing Next) | Full player → **Queue** |
| Crossfade duration / curve / silence-skip | Now Playing tab or Crossfade settings sheet |
| Dual PEQ (Target + Fine-Tune) | **Now Playing** dock tab |
| Banger shuffle | Shuffle button (Off → Standard → Banger) |
| Smart BPM Up Next | Crossfade settings → Smart BPM toggle |
| Themes | Hamburger menu (top left) |

---

## CLI build (optional)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /path/to/EQtargetsMusic

# Simulator example (name must match an installed simulator)
xcodebuild -scheme EQtargetsMusic \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug \
  -derivedDataPath build \
  build

# Device / arm64 Release (requires signing configured in Xcode first)
xcodebuild -scheme EQtargetsMusic \
  -destination 'generic/platform=iOS' \
  -configuration Release \
  build
```

---

## Troubleshooting

| Problem | Fix |
|--------|-----|
| **No signing team** | Add Apple ID in Xcode Settings → Accounts |
| **Bundle ID already in use** | Change Bundle Identifier under Signing |
| **Could not launch on device** | Unlock phone, trust developer, enable Developer Mode |
| **xcode-select / CLI tools only** | Install full Xcode app; `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| **Build fails with missing scheme** | Open `.xcodeproj` (not a random subfolder); scheme should be **EQtargetsMusic** |
| **No sound on Simulator** | Check Mac volume / Simulator I/O → Audio Output |

---

## Project layout (short)

```
EQtargetsMusic/
├── EQtargetsMusic.xcodeproj   ← open this
├── EQtargetsMusic/            ← Swift sources, Assets, Info.plist
│   ├── App/
│   ├── Models/
│   ├── Services/              ← audio engine, crossfade, library, shuffle
│   ├── Views/                 ← UI (player, library, EQ, queue)
│   └── Theme/
└── README.md                  ← this file
```

---

## Privacy note for testers

- Music stays **on device** (local library).
- No requirement to log into cloud services for basic play/EQ.
- Use only tracks you have rights to test with.

---

## License / sharing

Shared for private testing with friends. Ask the author before redistributing widely or publishing to the App Store under another account.
