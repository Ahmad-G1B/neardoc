# NearDoc

Private, local-only Mac ↔ Android companion app built with native Swift (macOS) and Java (Android).

No cloud accounts, no relay servers, no tracking. Everything stays on your USB cable or local Wi-Fi network.

## Features

- **Low-Latency Screen Mirroring & Control (USB & Wi-Fi):** Open apps, click, drag, swipe, scroll, and type on your Android phone directly from your Mac trackpad and keyboard.
- **Floating Phone Controls Bar:** Collapsible always-on-top bar (`◀ Back`, `● Home`, `▢ Recents`, `✕ Close App`, `🔔 Notifications`, `⚙ Quick Panel`, `📂 Files`, `📞 Answer`, `📵 Decline`, `⏻ Power`) so you can control your phone without leaving the mirror window.
- **Button & Swipe Gesture Navigation:** Supports both 3-button and Android swipe gesture navigation.
- **Two-Way Drag & Drop File Transfer:**
  - **Mac → Phone:** Drag files onto the mirrored phone window or click **Send file to phone…** (transfers at full USB 3.2 speed when plugged in, or over local Wi-Fi).
  - **Phone → Mac:** Open **📂 Phone Files (Drag to Mac)** to browse Photos, Videos, Screen Recordings, Screenshots, Downloads, and Documents across all Android brands and drag them straight into Finder—with **Pause / Resume** and **Stop** controls on both Mac and Android.
- **Two-Way Clipboard Sync:** Copy and paste seamlessly between Mac and Android (`Cmd + C` / `Cmd + V` during mirroring, or via the NearDoc companion app over Wi-Fi).
- **Integrated macOS Notification Center & Call Controls:** Receive Android notifications directly in macOS Notification Center, and accept or decline incoming calls right from your Mac.
- **Phone Camera Preview & Screen Recording:** Preview your phone's front camera or record your mirrored screen to `.mp4`.
- **Convenience:** Keep your phone awake while mirroring (`--stay-awake`) and optionally keep your phone's physical screen dark on your desk (**Keep phone screen off while mirroring**).

## Requirements

- **macOS:** macOS 12.3 or newer (Apple Silicon or Intel)
- **Android:** Android 12 (API 31) or newer
- **Mac CLI tools (for mirroring & USB transfer):**
  ```bash
  brew install scrcpy android-platform-tools
  ```

## Quick Start

1. **Install on Mac:** Download `NearDoc-macOS.zip` from [Releases](../../releases), unzip it, and move **NearDoc.app** to **Applications**.
   - *First launch (unsigned open-source build):* Right-click **NearDoc.app → Open**, or run `xattr -cr /Applications/NearDoc.app` if macOS Gatekeeper warns about an unidentified developer.
2. **Install on Android:** Download `neardoc-android.apk` from [Releases](../../releases) and install it on your Android phone (or install over USB via `adb install -r neardoc-android.apk`).
3. **Enable USB Debugging on Android (works on Pixel, Samsung, OnePlus, Xiaomi, Motorola, Nothing, etc.):**
   - Open **Settings → About phone** (or **Software information**) and tap **Build number** 7 times.
   - Open **Settings → Developer options** and enable **USB debugging** (and **Wireless debugging** for cable-free Wi-Fi mirroring).
   - *Xiaomi / Redmi / POCO (MIUI / HyperOS):* Also enable **USB debugging (Security settings)** in Developer options to allow Mac mouse/keyboard control.
   - *Oppo / OnePlus / Realme:* If touch input is blocked, enable **Disable permission monitoring** in Developer options.
4. **Connect:**
   - Plug in via USB (a USB 3.2 data cable is recommended for fast multi-GB video transfers) and click **USB** in NearDoc, or click **Connect over Wi-Fi (No USB)** on the same local Wi-Fi network.
   - Click **Pair phone with QR** in NearDoc and scan it in the Android **NearDoc** app for Wi-Fi file transfers, clipboard sync, and macOS Notification Center alerts.

## Building from Source

### macOS
```bash
bash scripts/build-macos.sh
```
Produces `build/NearDoc.app` and `dist/NearDoc-macOS.dmg` (or `dist/NearDoc-macOS.zip`).

### Android
Set your Android SDK path in `android/local.properties` (`sdk.dir=/path/to/Android/sdk`), then run:
```bash
bash scripts/build-android.sh
```

## Privacy & Security

See [PRIVACY.md](PRIVACY.md). NearDoc never connects to external servers; all local Wi-Fi pairing and session requests are authenticated with per-session HMAC-SHA256 tokens.

## Trademarks & Non-Affiliation

This is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Apple Inc., Google LLC, Samsung Electronics, Xiaomi, or OnePlus/OPPO. macOS is a trademark of Apple Inc. Android is a trademark of Google LLC. All other trademarks belong to their respective owners.

## License

MIT License — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
