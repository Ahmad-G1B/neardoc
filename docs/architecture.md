# Architecture contract

## Products

`Local Link for Android` is a Kotlin/Java Android application. `Local Link for Mac` is a native Swift application. They use a small versioned protocol called LL/1.

## Pairing and transport

1. The Mac displays a QR code containing a short-lived pairing endpoint, protocol version, Mac public key, and a random nonce.
2. The phone scans it, shows the Mac's name and a six-word verification phrase, and asks the user to confirm.
3. Each side creates an ephemeral key agreement and derives a session key. The long-lived device public keys are saved only after the user confirms the phrase on both devices.
4. Later connections use mutual authentication from the stored keys and are encrypted. A pairing ticket expires after two minutes and is single-use.

The endpoint must be a USB tunnel or private LAN address. Internet-routable endpoints and cloud relays are intentionally rejected.

## Capabilities

Capabilities are negotiated individually for every connection:

| Capability | Android approval | Notes |
| --- | --- | --- |
| files | Android file picker | Uses user-selected files; no broad storage scan. |
| screen | MediaProjection prompt | Android shows its own capture prompt for each session. |
| camera | Camera permission | Separate from screen sharing. |
| notifications | Notification listener setting | Preview/reply support remains opt-in. |
| input | Accessibility setting | Private-build feature only until Play-policy review is completed. |
| clipboard | Session opt-in | Best effort; no background clipboard surveillance. |

The Mac must show an active-session indicator and a one-click Disconnect action. The Android foreground-service notification must say what is sharing and provide Stop.

## Implementation order

- **Foundation (current):** package structure, consent-first Android shell, foreground capture service contract, protocol contract, and independent Mac target.
- **Milestone 1:** encrypted pairing plus trusted-device store and one-direction file transfer.
- **Milestone 2:** H.264/HEVC screen transport with adaptive bitrate; never raw JPEG frames.
- **Milestone 3:** remote input, notifications, and clipboard as independent permissions.
- **Milestone 4:** camera and Core Media I/O virtual camera extension.

## Out of scope

- iPhone support, cellular/internet relay, phone call recording, device-management features, bypassing Android protected screens, and any automatic action on the phone.
