# NearDoc Architecture

## Overview

NearDoc is a 100% local-only Mac ↔ Android companion composed of two native apps:

- **NearDoc for macOS** (`macos/Sources/`): Native Swift / AppKit application.
- **NearDoc for Android** (`android/app/src/main/java/com/locallink/android/`): Native Java Android companion application.

All communication stays strictly over USB or the local Wi-Fi network. NearDoc has no cloud backend, no relay servers, and no telemetry.

## Components

### 1. Screen Mirroring, Input & Camera (`main.swift`, `ToolLocator.swift`, `WirelessQrPairer.swift`)
- Auto-discovers `adb` and `scrcpy` across bundled app resources, Apple Silicon Homebrew (`/opt/homebrew/bin`), Intel Homebrew (`/usr/local/bin`), Android Studio SDK, and `PATH`.
- Launches `scrcpy` over USB or local Wi-Fi with free-cursor input (`--mouse=sdk --keyboard=sdk`), `--stay-awake`, optional `--turn-screen-off`, and `--push-target=/sdcard/Download/NearDoc/`.
- Supports Wireless Debugging pairing via both 6-digit pairing code (`adb pair`) and QR code (local mDNS `_adb-tls-pairing._tcp`).
- Provides an always-on-top collapsible **Phone Controls** bar for Back, Home, Recents, Close App, Notifications, Quick Panel, Phone Files, Answer/Decline Call, and Power.

### 2. Fast USB / Wi-Fi File Drag & Drop (`PhoneFilesPanel.swift`, `main.swift`)
- **Mac → Phone:** Dragging onto the mirror window (`scrcpy` push target) or using **Send file to phone…** runs `adb push` into `/sdcard/Download/NearDoc/` and triggers Android's media scanner.
- **Phone → Mac:** `PhoneFilesPanel` lists universal Android folders (All Recent Videos, Camera, Screenshots, Screen Recordings, Movies, Downloads, NearDoc Folder, Documents) and uses `NSFilePromiseProvider` + `adb pull` for native drag-out to Finder, with Pause/Resume (`SIGSTOP`/`SIGCONT`) and Stop controls.

### 3. Local Wi-Fi Pairing, File Transfer, Clipboard & Notifications (`PairingHost.swift`, `PairingClient.java`, `NotificationBridgeService.java`)
- **Pairing:** The Mac starts a local TCP listener (preferred port `39874`) and displays a QR code containing the local IPv4 address, port, and a single-use pairing secret. Both sides perform an HMAC-SHA256 challenge-response handshake and store a per-session token locally.
- **File Streaming:** Large files stream directly over TCP with 1 MB buffered disk writes on macOS and 256 KB chunked writes on Android, with Pause/Resume and Stop support on both devices.
- **Clipboard Sync:** On-demand two-way text clipboard sync (and automatic image/file URI fallback on Android).
- **Notifications & Calls:** `NotificationBridgeService` (opt-in Android Notification Listener) forwards phone notifications and incoming calls to macOS Notification Center (`UNUserNotificationCenter`), with interactive **Accept Call** and **Decline Call** actions.
