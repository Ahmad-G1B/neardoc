import AppKit
import CoreImage
import UserNotifications

@main
final class LinkBridgeApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var retained: LinkBridgeApp?
    private var window: NSWindow!
    private var status: NSTextField!
    private var pairedBadge: NSTextField!
    private var process: Process?
    private var mirrorApplication: NSRunningApplication?
    private let pairingHost = PairingHost()
    private var qrView: NSImageView!
    private var qrHint: NSTextField!
    private var sendFileButton: NSButton!
    private var pauseTransferButton: NSButton!
    private var stopTransferButton: NSButton!
    private var sendClipboardButton: NSButton!
    private var unpairButton: NSButton!
    private var screenOffCheckbox: NSButton!
    private var lastMirrorMode: String?
    private var navPanel: NSPanel?
    private var navActionButtons: [NSButton] = []
    private var navToggleButton: NSButton?
    private var navCollapsed = false
    private var phoneFilesPanel: PhoneFilesPanel?
    private var wirelessQrPairer: WirelessQrPairer?
    private var activePushProcess: Process?
    private var pushPaused = false
    private var pushCancelled = false
    private var log: [String] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = LinkBridgeApp(); retained = delegate; app.delegate = delegate
        app.setActivationPolicy(.regular); app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 690),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NearDoc"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = makeView()
        setupMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let icon = logoImage() { NSApp.applicationIconImage = icon }

        pairingHost.onStatus = { [weak self] message in
            DispatchQueue.main.async {
                self?.status.stringValue = message
                self?.record(message)
            }
        }
        pairingHost.onPairingCode = { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                if let code {
                    self.qrView.image = self.makeQRCode(code)
                    self.qrView.isHidden = false
                    self.qrHint.isHidden = false
                } else {
                    self.qrView.image = nil
                    self.qrView.isHidden = true
                    self.qrHint.isHidden = true
                }
            }
        }
        pairingHost.onPairedStateChanged = { [weak self] paired, name in
            DispatchQueue.main.async {
                self?.refreshPairedUI(paired: paired, deviceName: name)
            }
        }
        pairingHost.onFileReceived = { [weak self] url in
            DispatchQueue.main.async {
                self?.record("Received file: \(url.path)")
            }
        }
        pairingHost.onNotificationReceived = { [weak self] appName, title, body, _, isCall in
            self?.postMacNotification(appName: appName, title: title, body: body, isCall: isCall)
        }
        pairingHost.onTransferStateChanged = { [weak self] active, paused in
            DispatchQueue.main.async {
                guard let self else { return }
                let anyActive = active || (self.activePushProcess?.isRunning == true)
                self.pauseTransferButton.isEnabled = anyActive
                self.stopTransferButton.isEnabled = anyActive
                self.pauseTransferButton.title = paused ? "▶ Resume transfer" : "⏸ Pause transfer"
            }
        }

        setupMacNotifications()
        refreshPairedUI(paired: pairingHost.isPaired, deviceName: pairingHost.pairedDeviceName)
        pairingHost.startIfPaired()
        record("NearDoc opened")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        process?.terminate()
        process = nil
        wirelessQrPairer?.stop(clearQR: false)
        pairingHost.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show NearDoc Window", action: #selector(reopenMainWindow), keyEquivalent: "0")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide NearDoc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit NearDoc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func reopenMainWindow() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMacNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let openAction = UNNotificationAction(identifier: "OPEN_MIRROR", title: "Open Phone Mirror", options: [.foreground])
        let acceptCall = UNNotificationAction(identifier: "ACCEPT_CALL", title: "Accept Call", options: [])
        let declineCall = UNNotificationAction(identifier: "DECLINE_CALL", title: "Decline Call", options: [.destructive])
        let msgCategory = UNNotificationCategory(identifier: "BRIDGE_PHONE_NOTIF", actions: [openAction], intentIdentifiers: [], options: [])
        let callCategory = UNNotificationCategory(identifier: "BRIDGE_INCOMING_CALL", actions: [acceptCall, declineCall, openAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([msgCategory, callCategory])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error { self?.record("Notification auth error: \(error.localizedDescription)") }
                else { self?.record("macOS Notification Center permission: \(granted ? "granted" : "denied")") }
            }
        }
    }

    private func postMacNotification(appName: String, title: String, body: String, isCall: Bool) {
        let content = UNMutableNotificationContent()
        if isCall {
            content.title = title.isEmpty ? "Incoming Call" : "Incoming Call — \(title)"
            content.body = body.isEmpty ? "Accept or decline from your Mac." : body
            content.categoryIdentifier = "BRIDGE_INCOMING_CALL"
        } else {
            content.title = title.isEmpty ? appName : "\(appName) — \(title)"
            content.body = body
            content.categoryIdentifier = "BRIDGE_PHONE_NOTIF"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.record("Mac notification error: \(error.localizedDescription)") } }
        }
        record("Phone notification: \(content.title)")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch response.actionIdentifier {
            case "ACCEPT_CALL":
                self.acceptCall()
            case "DECLINE_CALL":
                self.declineCall()
            default:
                if let app = self.mirrorApplication {
                    app.activate(options: [.activateAllWindows])
                } else {
                    self.connectWiFi()
                }
            }
        }
        completionHandler()
    }

    private func makeView() -> NSView {
        let root = NSView()

        let logo = NSImageView()
        logo.image = logoImage()
        logo.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "NearDoc")
        title.font = .boldSystemFont(ofSize: 28)

        pairedBadge = NSTextField(labelWithString: "Not paired over Wi-Fi")
        pairedBadge.font = .systemFont(ofSize: 13, weight: .medium)
        pairedBadge.textColor = .secondaryLabelColor

        let subtitle = NSTextField(wrappingLabelWithString: "Private, local-only Mac ↔ Android companion: low-latency mirroring, trackpad navigation, drag-and-drop files, clipboard sync, notifications, and camera preview.")
        subtitle.maximumNumberOfLines = 0
        subtitle.textColor = .secondaryLabelColor

        // Left column: controls
        let controlsStack = NSStackView()
        controlsStack.orientation = .vertical
        controlsStack.alignment = .leading
        controlsStack.spacing = 11

        let mirrorHeader = sectionHeader("SCREEN MIRRORING & CAMERA (USB / WI-FI)")
        let wifi = makeButton("Connect over Wi-Fi (No USB)", action: #selector(connectWiFi))
        let pairWifiQr = makeButton("Pair Wi-Fi (QR)", action: #selector(pairWirelessDebuggingQR))
        let pairWifiCode = makeButton("Pair Wi-Fi (Code)", action: #selector(pairWirelessDebugging))
        let connect = makeButton("USB", action: #selector(connectUSB))
        let stop = makeButton("Stop", action: #selector(stopMirror))
        let mirrorRow1 = row([wifi, pairWifiQr, pairWifiCode, connect, stop])

        let recordBtn = makeButton("Record mirror…", action: #selector(recordMirror))
        let cameraBtn = makeButton("Phone camera preview", action: #selector(cameraPreview))
        let floatBtn = makeButton("Phone Controls bar", action: #selector(openFloatingNavManual))
        let logsBtn = makeButton("Show log", action: #selector(showLog))
        let mirrorRow2 = row([recordBtn, cameraBtn, floatBtn, logsBtn])

        screenOffCheckbox = NSButton(checkboxWithTitle: "Keep phone screen off while mirroring (convenience & battery)", target: self, action: #selector(screenOffCheckboxChanged))
        screenOffCheckbox.state = UserDefaults.standard.bool(forKey: "bridge.keepScreenOff") ? .on : .off

        let navHeader = sectionHeader("PHONE NAVIGATION — BUTTONS & SWIPE GESTURES")
        let backBtn = makeButton("◀ Back", action: #selector(sendBackKey))
        let homeBtn = makeButton("● Home", action: #selector(sendHomeKey))
        let recentsBtn = makeButton("▢ Recents", action: #selector(sendRecentsKey))
        let powerBtn = makeButton("⏻ Wake / Sleep", action: #selector(sendPowerKey))
        let navButtonRow = row([backBtn, homeBtn, recentsBtn, powerBtn])

        let swipeBackBtn = makeButton("→ Swipe Back", action: #selector(swipeBackGesture))
        let swipeHomeBtn = makeButton("↑ Swipe Home", action: #selector(swipeHomeGesture))
        let swipeRecentsBtn = makeButton("↑ Hold Recents", action: #selector(swipeRecentsGesture))
        let swipeCloseBtn = makeButton("✕ Swipe Up (Close)", action: #selector(swipeCloseAppGesture))
        let navGestureRow = row([swipeBackBtn, swipeHomeBtn, swipeRecentsBtn, swipeCloseBtn])

        let notifsBtn = makeButton("🔔 Notifications", action: #selector(openNotifications))
        let panelBtn = makeButton("⚙ Quick Panel", action: #selector(openQuickPanel))
        let answerBtn = makeButton("📞 Answer Call", action: #selector(acceptCall))
        let declineBtn = makeButton("📵 Decline / End", action: #selector(declineCall))
        let shadeRow = row([notifsBtn, panelBtn, answerBtn, declineBtn])

        let navHint = NSTextField(wrappingLabelWithString: "Drag Mac files onto mirror window to send · Two-finger click = Back · Option+H = Home · Option+S = Recents · Cmd+V = Paste")
        navHint.font = .systemFont(ofSize: 11)
        navHint.textColor = .secondaryLabelColor
        navHint.maximumNumberOfLines = 2

        let transferHeader = sectionHeader("DRAG & DROP FILES, CLIPBOARD & NOTIFICATIONS")
        let phoneFilesBtn = makeButton("📂 Phone Files (Drag to Mac)", action: #selector(openPhoneFilesPanel))
        sendFileButton = makeButton("Send file to phone…", action: #selector(sendFileToPhone))
        let openReceived = makeButton("Open received folder", action: #selector(openReceivedFolder))
        let transferRow = row([phoneFilesBtn, sendFileButton, openReceived])

        pauseTransferButton = makeButton("⏸ Pause transfer", action: #selector(togglePauseMacTransfer))
        pauseTransferButton.isEnabled = false
        stopTransferButton = makeButton("⏹ Stop transfer", action: #selector(stopMacTransfer))
        stopTransferButton.isEnabled = false
        let transferCtrlRow = row([pauseTransferButton, stopTransferButton])

        sendClipboardButton = makeButton("Sync Mac clipboard", action: #selector(sendClipboardToPhone))
        let pairQR = makeButton("Pair phone with QR", action: #selector(beginPairingQR))
        unpairButton = makeButton("Unpair", action: #selector(unpairPhone))
        let pairRow = row([sendClipboardButton, pairQR, unpairButton])

        [mirrorHeader, mirrorRow1, mirrorRow2, screenOffCheckbox,
         navHeader, navButtonRow, navGestureRow, shadeRow, navHint,
         transferHeader, transferRow, transferCtrlRow, pairRow].forEach {
            controlsStack.addArrangedSubview($0)
        }
        controlsStack.setCustomSpacing(16, after: screenOffCheckbox)
        controlsStack.setCustomSpacing(18, after: navHint)

        status = NSTextField(wrappingLabelWithString: "Ready. Start USB or Wi-Fi mirroring, or send files directly to your Android phone.")
        status.maximumNumberOfLines = 4
        status.font = .systemFont(ofSize: 13)

        // Right column: QR code card
        qrView = NSImageView()
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.isHidden = true

        qrHint = NSTextField(wrappingLabelWithString: "Scan with NearDoc on your phone. Keep both devices on the same Wi-Fi.")
        qrHint.alignment = .center
        qrHint.font = .systemFont(ofSize: 12)
        qrHint.textColor = .secondaryLabelColor
        qrHint.maximumNumberOfLines = 3
        qrHint.isHidden = true

        [logo, title, pairedBadge, subtitle, controlsStack, status, qrView, qrHint].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            logo.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            logo.widthAnchor.constraint(equalToConstant: 54),
            logo.heightAnchor.constraint(equalToConstant: 54),

            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: logo.topAnchor, constant: 2),

            pairedBadge.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pairedBadge.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),

            subtitle.leadingAnchor.constraint(equalTo: logo.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            subtitle.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 12),

            controlsStack.leadingAnchor.constraint(equalTo: logo.leadingAnchor),
            controlsStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: qrView.leadingAnchor, constant: -20),

            qrView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            qrView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            qrView.widthAnchor.constraint(equalToConstant: 200),
            qrView.heightAnchor.constraint(equalToConstant: 200),

            qrHint.leadingAnchor.constraint(equalTo: qrView.leadingAnchor),
            qrHint.trailingAnchor.constraint(equalTo: qrView.trailingAnchor),
            qrHint.topAnchor.constraint(equalTo: qrView.bottomAnchor, constant: 8),

            status.leadingAnchor.constraint(equalTo: logo.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)
        ])
        return root
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        return btn
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func refreshPairedUI(paired: Bool, deviceName: String) {
        // Send file & clipboard work via ADB (USB/Wi-Fi) even without QR pairing, so keep them enabled!
        sendFileButton.isEnabled = true
        sendClipboardButton.isEnabled = true
        unpairButton.isEnabled = paired
        if paired {
            let label = deviceName.isEmpty ? "Android Phone" : deviceName
            pairedBadge.stringValue = "Paired over Wi-Fi with \(label)"
            pairedBadge.textColor = .systemGreen
        } else {
            pairedBadge.stringValue = "Not paired over Wi-Fi (ADB transfer still available)"
            pairedBadge.textColor = .secondaryLabelColor
        }
    }

    private func logoImage() -> NSImage? {
        guard let path = Bundle.main.path(forResource: "LinkBridgeLogo", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func makeQRCode(_ value: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    }

    // MARK: - ADB Device Resolution & Phone Navigation

    private func toolEnvironment() -> [String: String] {
        ToolLocator.environment()
    }

    private func activeAdbSerial() -> String? {
        guard let listed = try? run(ToolLocator.adbPath(), ["devices"]) else { return nil }
        let rows = listed.components(separatedBy: .newlines)
            .filter { $0.contains("\tdevice") && !$0.hasPrefix("List of") }
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        // Prefer USB if plugged in, otherwise Wi-Fi serial.
        return rows.first(where: { !$0.contains(":") }) ?? rows.first
    }

    private func sendKeyEvent(_ keycode: Int, label: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let serial = self.activeAdbSerial() else {
                DispatchQueue.main.async { self.status.stringValue = "No USB or Wi-Fi ADB phone connected for \(label)." }
                return
            }
            do {
                _ = try self.run(ToolLocator.adbPath(), ["-s", serial, "shell", "input", "keyevent", "\(keycode)"])
                DispatchQueue.main.async {
                    self.status.stringValue = "Sent \(label) to phone (\(serial))."
                    self.record("Keyevent \(label) (\(keycode)) -> \(serial)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "\(label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func screenSize(for serial: String) -> (Int, Int) {
        if let output = try? run(ToolLocator.adbPath(), ["-s", serial, "shell", "wm", "size"]),
           let match = output.range(of: "\\d+x\\d+", options: .regularExpression) {
            let dims = String(output[match]).split(separator: "x").compactMap { Int($0) }
            if dims.count == 2, dims[0] > 0, dims[1] > 0 { return (dims[0], dims[1]) }
        }
        return (1080, 2340)
    }

    private func sendSwipe(label: String, compute: @escaping (Int, Int) -> (Int, Int, Int, Int, Int)) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let serial = self.activeAdbSerial() else {
                DispatchQueue.main.async { self.status.stringValue = "No USB or Wi-Fi ADB phone connected for \(label)." }
                return
            }
            let (w, h) = self.screenSize(for: serial)
            let (x1, y1, x2, y2, ms) = compute(w, h)
            do {
                _ = try self.run(ToolLocator.adbPath(), ["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(ms)"])
                DispatchQueue.main.async {
                    self.status.stringValue = "Performed \(label) gesture on phone (\(serial))."
                    self.record("Swipe \(label): (\(x1),\(y1))->(\(x2),\(y2)) in \(ms)ms")
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "\(label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func sendBackKey() { sendKeyEvent(4, label: "Back") }
    @objc private func sendHomeKey() { sendKeyEvent(3, label: "Home") }
    @objc private func sendRecentsKey() { sendKeyEvent(187, label: "Recents") }
    @objc private func sendPowerKey() { sendKeyEvent(26, label: "Wake / Sleep") }
    @objc private func acceptCall() { sendKeyEvent(5, label: "Accept Call") }
    @objc private func declineCall() { sendKeyEvent(6, label: "Decline / End Call") }

    @objc private func swipeBackGesture() {
        sendSwipe(label: "Swipe Back") { w, h in (12, h / 2, Int(Double(w) * 0.42), h / 2, 180) }
    }
    @objc private func swipeHomeGesture() {
        sendSwipe(label: "Swipe Home") { w, h in (w / 2, h - 18, w / 2, Int(Double(h) * 0.65), 180) }
    }
    @objc private func swipeRecentsGesture() {
        sendSwipe(label: "Hold Recents") { w, h in (w / 2, h - 18, w / 2, Int(Double(h) * 0.56), 650) }
    }
    @objc private func swipeCloseAppGesture() {
        sendSwipe(label: "Swipe Up (Close App)") { w, h in (w / 2, Int(Double(h) * 0.65), w / 2, Int(Double(h) * 0.14), 180) }
    }

    private func runStatusBar(_ subcommand: String, label: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let serial = self.activeAdbSerial() else {
                DispatchQueue.main.async { self.status.stringValue = "No USB or Wi-Fi ADB phone connected for \(label)." }
                return
            }
            do {
                _ = try self.run(ToolLocator.adbPath(), ["-s", serial, "shell", "cmd", "statusbar", subcommand])
                DispatchQueue.main.async {
                    self.status.stringValue = "Opened \(label) on phone (\(serial))."
                    self.record("StatusBar \(subcommand) -> \(serial)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "\(label) failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func openNotifications() { runStatusBar("expand-notifications", label: "Notifications") }
    @objc private func openQuickPanel() { runStatusBar("expand-settings", label: "Quick Panel") }
    @objc private func collapseShade() { runStatusBar("collapse", label: "Close Shade") }

    // MARK: - QR Pairing, Files & Clipboard

    @objc private func beginPairingQR() {
        qrView.image = nil
        qrView.isHidden = false
        status.stringValue = "Starting a private pairing listener…"
        do { try pairingHost.beginPairing() }
        catch {
            status.stringValue = "Could not start QR pairing: \(error.localizedDescription)"
            record("QR pairing failed: \(error.localizedDescription)")
        }
    }

    @objc private func unpairPhone() {
        pairingHost.unpair()
    }

    @objc private func togglePauseMacTransfer() {
        if let proc = activePushProcess, proc.isRunning {
            pushPaused.toggle()
            kill(proc.processIdentifier, pushPaused ? SIGSTOP : SIGCONT)
            pauseTransferButton.title = pushPaused ? "▶ Resume transfer" : "⏸ Pause transfer"
            status.stringValue = pushPaused ? "USB file transfer paused. Click Resume transfer to continue." : "Resuming USB file transfer…"
            return
        }
        let paused = pairingHost.togglePauseTransfer()
        pauseTransferButton.title = paused ? "▶ Resume transfer" : "⏸ Pause transfer"
    }

    @objc private func stopMacTransfer() {
        pushCancelled = true
        if let proc = activePushProcess, proc.isRunning {
            if pushPaused { kill(proc.processIdentifier, SIGCONT) }
            proc.terminate()
        }
        pushPaused = false
        pairingHost.stopActiveTransfer()
        pauseTransferButton.title = "⏸ Pause transfer"
        pauseTransferButton.isEnabled = false
        stopTransferButton.isEnabled = false
        status.stringValue = "File transfer stopped."
    }

    private func runAdbPush(_ serial: String, localPath: String, remotePath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.adbPath())
        proc.arguments = ["-s", serial, "push", localPath, remotePath]
        proc.environment = toolEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        activePushProcess = proc
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        activePushProcess = nil
        if pushCancelled {
            throw NSError(domain: "NearDoc", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer stopped by user."])
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8) ?? "adb push failed"
            throw NSError(domain: "NearDoc", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    @objc private func sendFileToPhone() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send to Phone"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls

        // Fast path: push immediately over ADB (works over USB or Wi-Fi even if Android app is closed!)
        if let serial = activeAdbSerial() {
            pushCancelled = false
            pushPaused = false
            pauseTransferButton.title = "⏸ Pause transfer"
            pauseTransferButton.isEnabled = true
            stopTransferButton.isEnabled = true
            status.stringValue = "Sending \(urls.count) file(s) to phone Downloads/NearDoc…"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    _ = try self.run(ToolLocator.adbPath(), ["-s", serial, "shell", "mkdir", "-p", "/sdcard/Download/NearDoc"])
                    var sentNames: [String] = []
                    for (idx, url) in urls.enumerated() {
                        if self.pushCancelled { break }
                        let name = url.lastPathComponent
                        DispatchQueue.main.async {
                            self.status.stringValue = "Sending (\(idx + 1)/\(urls.count)): \(name)…"
                        }
                        let remotePath = "/sdcard/Download/NearDoc/\(name)"
                        try self.runAdbPush(serial, localPath: url.path, remotePath: remotePath)
                        _ = try? self.run(ToolLocator.adbPath(), ["-s", serial, "shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://\(remotePath)"])
                        sentNames.append(name)
                    }
                    let summary = sentNames.joined(separator: ", ")
                    DispatchQueue.main.async {
                        self.pauseTransferButton.title = "⏸ Pause transfer"
                        self.pauseTransferButton.isEnabled = false
                        self.stopTransferButton.isEnabled = false
                        if !self.pushCancelled {
                            self.status.stringValue = "Sent to phone Downloads/NearDoc: \(summary)"
                            self.record("ADB pushed \(sentNames.count) file(s) to \(serial): \(summary)")
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.pauseTransferButton.title = "⏸ Pause transfer"
                        self.pauseTransferButton.isEnabled = false
                        self.stopTransferButton.isEnabled = false
                        self.status.stringValue = self.pushCancelled ? "File transfer stopped." : "File transfer failed: \(error.localizedDescription)"
                        self.record("ADB push ended: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        // Fallback: Wi-Fi QR bridge queue
        guard pairingHost.isPaired else {
            status.stringValue = "Connect your Android phone via USB/Wi-Fi mirroring or pair with QR first."
            return
        }
        let count = pairingHost.queueFilesForPhone(urls)
        if count > 0 {
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            status.stringValue = "Queued \(count) file(s) for Wi-Fi transfer: \(names). Open the companion app on your phone to receive."
            record("Queued \(count) file(s) for phone: \(names)")
        }
    }

    @objc private func sendClipboardToPhone() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status.stringValue = "Mac clipboard has no text to send."
            return
        }
        var queued = false
        if pairingHost.isPaired {
            queued = pairingHost.queueClipboardForPhone(text)
        }
        if process?.isRunning == true {
            status.stringValue = "Clipboard ready (\(text.count) chars). Press Cmd+V inside the phone mirror window to paste, or open the phone app."
        } else if queued {
            status.stringValue = "Queued Mac clipboard (\(text.count) chars). Open the phone app (or tap Get Mac clipboard)."
        } else {
            status.stringValue = "Start mirroring (then press Cmd+V in the mirror) or pair with QR to sync clipboard."
        }
        record("Prepared Mac clipboard (\(text.count) chars) for phone")
    }

    @objc private func openReceivedFolder() {
        let folder = pairingHost.receivedFilesDirectory()
        NSWorkspace.shared.open(folder)
    }

    @objc private func openPhoneFilesPanel() {
        if phoneFilesPanel == nil {
            phoneFilesPanel = PhoneFilesPanel(
                activeSerialProvider: { [weak self] in self?.activeAdbSerial() },
                runAdb: { [weak self] args in
                    guard let self else { return "" }
                    return try self.run(ToolLocator.adbPath(), args)
                },
                adbEnvProvider: { [weak self] in self?.toolEnvironment() ?? [:] },
                receivedDirProvider: { [weak self] in
                    self?.pairingHost.receivedFilesDirectory()
                        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                }
            )
        }
        phoneFilesPanel?.show()
    }

    @objc private func screenOffCheckboxChanged() {
        let keepOff = (screenOffCheckbox.state == .on)
        UserDefaults.standard.set(keepOff, forKey: "bridge.keepScreenOff")
        if process?.isRunning == true, let mode = lastMirrorMode {
            status.stringValue = keepOff ? "Applying screen-off mode…" : "Turning phone screen back on…"
            if mode == "wifi" { connectWiFi() } else { connectUSB() }
        }
    }

    private func mirrorConvenienceFlags() -> [String] {
        var flags = ["--stay-awake", "--push-target=/sdcard/Download/NearDoc/"]
        if screenOffCheckbox?.state == .on {
            flags.append("--turn-screen-off")
        }
        return flags
    }

    // MARK: - Screen Mirroring, Recording & Camera

    @objc private func recordMirror() {
        guard process == nil else { status.stringValue = "Stop the current session before starting a recording."; return }
        guard let serial = activeAdbSerial() else {
            status.stringValue = "No USB or Wi-Fi ADB phone connected to record."
            return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NearDoc-Recording.mp4"; panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        launchScrcpy(
            ["-s", serial, "--max-size=1024", "--video-bit-rate=6M", "--max-fps=60", "--video-codec=h264", "--no-audio", "--mouse=sdk", "--keyboard=sdk", "--record", url.path],
            statusText: "Recording your phone screen to \(url.lastPathComponent)…",
            endLabel: "Recording ended"
        )
    }

    @objc private func cameraPreview() {
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            self.process = nil
        }
        guard let serial = activeAdbSerial() else {
            status.stringValue = "No USB or Wi-Fi ADB phone connected for camera preview."
            return
        }
        // Camera mode works over USB or Wi-Fi, uses --camera-size (not --max-size), and must NOT pass control flags.
        launchScrcpy(
            ["-s", serial, "--video-source=camera", "--camera-facing=front", "--camera-size=1280x720", "--no-audio"],
            statusText: "Showing front phone camera preview from \(serial).",
            endLabel: "Camera preview ended"
        )
    }

    private func launchScrcpy(_ arguments: [String], statusText: String, endLabel: String) {
        let scrcpyPath = ToolLocator.scrcpyPath()
        guard FileManager.default.isExecutableFile(atPath: scrcpyPath) else {
            status.stringValue = "scrcpy was not found. Install with: brew install scrcpy android-platform-tools"
            record("scrcpy missing")
            return
        }
        let mirror = Process()
        mirror.executableURL = URL(fileURLWithPath: scrcpyPath)
        mirror.arguments = arguments
        mirror.environment = toolEnvironment()

        let outputPipe = Pipe()
        mirror.standardOutput = outputPipe
        mirror.standardError = outputPipe

        mirror.terminationHandler = { [weak self] p in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let errorLine = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last
            DispatchQueue.main.async {
                self?.process = nil
                self?.mirrorApplication = nil
                self?.hideFloatingNav()
                if p.terminationStatus != 0, let errorLine {
                    self?.status.stringValue = "\(endLabel) (\(p.terminationStatus)): \(errorLine)"
                } else {
                    self?.status.stringValue = "\(endLabel) (\(p.terminationStatus))."
                }
                self?.record("scrcpy exited (\(p.terminationStatus)): \(errorLine ?? "no output")")
            }
        }

        do {
            try mirror.run()
            process = mirror
            focusMirror(mirror)
            if !arguments.contains("--video-source=camera") {
                showFloatingNav()
            }
            status.stringValue = statusText
            record("scrcpy started: \(arguments.joined(separator: " "))")
        } catch {
            status.stringValue = "Could not start scrcpy: \(error.localizedDescription)"
            record("scrcpy launch error: \(error.localizedDescription)")
        }
    }

    private func discoverWirelessEndpoint() -> String? {
        guard let output = try? run(ToolLocator.adbPath(), ["mdns", "services"]) else { return nil }
        for line in output.components(separatedBy: .newlines) where line.contains("_adb-tls-connect._tcp") {
            if let match = line.range(of: "\\d{1,3}(?:\\.\\d{1,3}){3}:\\d+", options: .regularExpression) {
                return String(line[match])
            }
        }
        return nil
    }

    @objc private func pairWirelessDebuggingQR() {
        if wirelessQrPairer == nil {
            let pairer = WirelessQrPairer(runAdb: { [weak self] args in
                guard let self else { return "" }
                return try self.run(ToolLocator.adbPath(), args)
            })
            pairer.onStatus = { [weak self] msg in
                DispatchQueue.main.async {
                    self?.status.stringValue = msg
                    self?.record(msg)
                }
            }
            pairer.onQrPayload = { [weak self] payload in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let payload {
                        self.qrView.image = self.makeQRCode(payload)
                        self.qrView.isHidden = false
                        self.qrHint.stringValue = "Scan in Android Settings → Developer options → Wireless debugging → Pair device with QR code."
                        self.qrHint.isHidden = false
                    } else {
                        self.qrView.image = nil
                        self.qrView.isHidden = true
                        self.qrHint.stringValue = "Scan with NearDoc on your phone. Keep both devices on the same Wi-Fi."
                        self.qrHint.isHidden = true
                    }
                }
            }
            pairer.onPaired = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.connectWiFi()
                }
            }
            wirelessQrPairer = pairer
        }
        wirelessQrPairer?.start()
    }

    @objc private func pairWirelessDebugging() {
        wirelessQrPairer?.stop(clearQR: true)
        let alert = NSAlert()
        alert.messageText = "Pair Wireless Debugging (6-Digit Code)"
        alert.informativeText = "On your Android phone: Settings → Developer options → Wireless debugging → Pair device with pairing code. Keep that popup OPEN and enter the IP:Port shown inside it."
        alert.addButton(withTitle: "Pair & Connect")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        let hostField = NSTextField(frame: NSRect(x: 0, y: 36, width: 320, height: 24))
        hostField.placeholderString = "IP address & Port (e.g. 192.168.1.50:37123)"
        let codeField = NSTextField(frame: NSRect(x: 0, y: 4, width: 320, height: 24))
        codeField.placeholderString = "6-digit Wi-Fi pairing code"
        container.addSubview(hostField)
        container.addSubview(codeField)
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let hostPort = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairCode = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostPort.isEmpty, !pairCode.isEmpty else {
            status.stringValue = "Enter both the IP:Port and 6-digit pairing code from Wireless debugging."
            return
        }

        status.stringValue = "Pairing wirelessly with \(hostPort)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.run(ToolLocator.adbPath(), ["pair", hostPort, pairCode])
                DispatchQueue.main.async {
                    self.record("adb pair \(hostPort): \(result.trimmingCharacters(in: .whitespacesAndNewlines))")
                    self.status.stringValue = "Wireless debugging paired! Connecting over Wi-Fi…"
                    self.connectWiFi()
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "Wireless pairing failed: \(error.localizedDescription)"
                    self.record("adb pair failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func isEndpointOnline(_ endpoint: String) -> Bool {
        guard let listed = try? run(ToolLocator.adbPath(), ["devices"]) else { return false }
        return listed.components(separatedBy: .newlines).contains {
            $0.hasPrefix(endpoint + "\tdevice")
        }
    }

    private func connectAndVerify(_ endpoint: String, retries: Int = 3) -> Bool {
        for attempt in 1...retries {
            let out = (try? run(ToolLocator.adbPath(), ["connect", endpoint])) ?? ""
            record("adb connect \(endpoint) (try \(attempt)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            if isEndpointOnline(endpoint) { return true }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return false
    }

    private func promptForWirelessEndpoint() -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect over Wi-Fi (No USB)"
        alert.informativeText = "Auto-discovery did not find your phone on this Wi-Fi network.\n\nOn your Android phone, open Settings → Developer options → Wireless debugging and enter the IP address & Port shown there:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. 192.168.1.50:41892"
        if let saved = UserDefaults.standard.string(forKey: "linkbridge.wifi.endpoint") {
            field.stringValue = saved
        }
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func phoneWiFiIP(usbSerial: String) -> String? {
        if let route = try? run(ToolLocator.adbPath(), ["-s", usbSerial, "shell", "ip", "route", "get", "1.1.1.1"]),
           let match = route.range(of: "(?<=\\bsrc )\\d{1,3}(?:\\.\\d{1,3}){3}", options: .regularExpression) {
            return String(route[match])
        }
        if let addr = try? run(ToolLocator.adbPath(), ["-s", usbSerial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"]),
           let match = addr.range(of: "(?<=\\binet )\\d{1,3}(?:\\.\\d{1,3}){3}", options: .regularExpression) {
            return String(addr[match])
        }
        return nil
    }

    @objc private func connectWiFi() {
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            self.process = nil
        }
        let savedKey = "linkbridge.wifi.endpoint"
        status.stringValue = "Connecting to your Android phone over Wi-Fi…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let listed = try self.run(ToolLocator.adbPath(), ["devices"])
                let deviceRows = listed.components(separatedBy: .newlines)
                    .filter { $0.contains("\tdevice") && !$0.hasPrefix("List of") }
                    .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }

                var resolvedEndpoint: String?

                // 1. Already connected over Wi-Fi?
                if let wifiSerial = deviceRows.first(where: { $0.contains(":") || $0.contains("_adb-tls-connect") }) {
                    resolvedEndpoint = wifiSerial
                }

                // 2. Auto-discover Wireless Debugging via mDNS
                if resolvedEndpoint == nil, let mdns = self.discoverWirelessEndpoint() {
                    DispatchQueue.main.async { self.status.stringValue = "Found phone on Wi-Fi (\(mdns)). Connecting…" }
                    if self.connectAndVerify(mdns, retries: 2) {
                        resolvedEndpoint = mdns
                    }
                }

                // 3. Try previously saved Wi-Fi endpoint
                if resolvedEndpoint == nil, let saved = UserDefaults.standard.string(forKey: savedKey), !saved.isEmpty {
                    if self.connectAndVerify(saved, retries: 1) {
                        resolvedEndpoint = saved
                    }
                }

                // 4. If USB is plugged in, read Wi-Fi IP FIRST (with wlan0 fallback), then enable tcpip 5555, wait, and connect!
                if resolvedEndpoint == nil, let usbSerial = deviceRows.first(where: { !$0.contains(":") }) {
                    DispatchQueue.main.async { self.status.stringValue = "Reading phone Wi-Fi IP and enabling wireless mode…" }
                    if let ip = self.phoneWiFiIP(usbSerial: usbSerial) {
                        let candidate = "\(ip):5555"
                        _ = try self.run(ToolLocator.adbPath(), ["-s", usbSerial, "tcpip", "5555"])
                        Thread.sleep(forTimeInterval: 2.0)
                        if self.connectAndVerify(candidate, retries: 4) {
                            resolvedEndpoint = candidate
                        }
                    }
                }

                // 5. Fallback: ask user for the IP:Port from Android Wireless Debugging screen (works even if router blocks mDNS)
                if resolvedEndpoint == nil {
                    var manual: String?
                    DispatchQueue.main.sync { manual = self.promptForWirelessEndpoint() }
                    if let manual {
                        DispatchQueue.main.async { self.status.stringValue = "Connecting to \(manual)…" }
                        if self.connectAndVerify(manual, retries: 2) {
                            resolvedEndpoint = manual
                        } else {
                            DispatchQueue.main.async {
                                self.status.stringValue = "Could not connect to \(manual). If you haven't paired yet, click Pair Wireless Debugging first."
                            }
                            return
                        }
                    } else {
                        DispatchQueue.main.async { self.status.stringValue = "Wi-Fi connection cancelled." }
                        return
                    }
                }

                guard let endpoint = resolvedEndpoint else { return }
                UserDefaults.standard.set(endpoint, forKey: savedKey)

                DispatchQueue.main.async {
                    self.lastMirrorMode = "wifi"
                    self.launchScrcpy(
                        ["-s", endpoint, "--max-size=1024", "--video-bit-rate=4M", "--max-fps=60", "--video-codec=h264", "--no-audio", "--mouse=sdk", "--keyboard=sdk"] + self.mirrorConvenienceFlags(),
                        statusText: "Wi-Fi mirror opened at \(endpoint). Drag Mac files onto the mirror window, or open Phone Files to drag out.",
                        endLabel: "Wi-Fi mirroring ended"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "Wi-Fi setup failed: \(error.localizedDescription)"
                    self.record("Wi-Fi setup error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.environment = toolEnvironment()
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        // Drain the pipe BEFORE waitUntilExit() to prevent 64 KB pipe buffer deadlocks on large video transfers.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "NearDoc", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    private func focusMirror(_ mirror: Process) {
        let pid = mirror.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard mirror.isRunning, let app = NSRunningApplication(processIdentifier: pid) else { return }
            self?.mirrorApplication = app
            app.activate(options: [.activateAllWindows])
            // Keep NearDoc window open (don't minimize) so Back/Home/Recents buttons stay handy.
        }
    }

    @objc private func connectUSB() {
        if let process, process.isRunning { process.terminationHandler = nil; process.terminate(); self.process = nil }
        let adb = ToolLocator.adbPath()
        guard FileManager.default.isExecutableFile(atPath: adb) else {
            status.stringValue = "ADB was not found on this Mac."; record("adb missing"); return
        }
        do {
            let devices = try run(adb, ["devices"])
            guard devices.components(separatedBy: .newlines).contains(where: { $0.contains("\tdevice") && !$0.contains(":") }) else {
                status.stringValue = "No authorized USB phone found. Unlock it, connect USB, and approve USB debugging."; record("No authorized USB device"); return
            }
            lastMirrorMode = "usb"
            launchScrcpy(
                ["--select-usb", "--max-size=1280", "--video-bit-rate=8M", "--max-fps=60", "--video-codec=h264", "--no-audio", "--mouse=sdk", "--keyboard=sdk"] + mirrorConvenienceFlags(),
                statusText: "USB mirror opened. Drag Mac files onto the mirror window, or open Phone Files to drag out.",
                endLabel: "Mirroring ended"
            )
        } catch {
            status.stringValue = "Could not start mirroring: \(error.localizedDescription)"
            record("Launch error: \(error.localizedDescription)")
        }
    }


    @objc private func openFloatingNavManual() {
        showFloatingNav()
    }

    private func showFloatingNav() {
        if navPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 48),
                styleMask: [.titled, .closable, .miniaturizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Phone Controls"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let toggle = makeButton("−", action: #selector(toggleFloatingNavSize))
            let actions: [NSButton] = [
                makeButton("◀ Back", action: #selector(sendBackKey)),
                makeButton("● Home", action: #selector(sendHomeKey)),
                makeButton("▢ Recents", action: #selector(sendRecentsKey)),
                makeButton("✕ Close", action: #selector(swipeCloseAppGesture)),
                makeButton("🔔 Notifs", action: #selector(openNotifications)),
                makeButton("⚙ Panel", action: #selector(openQuickPanel)),
                makeButton("📂 Files", action: #selector(openPhoneFilesPanel)),
                makeButton("📞 Answer", action: #selector(acceptCall)),
                makeButton("📵 Decline", action: #selector(declineCall)),
                makeButton("⏻", action: #selector(sendPowerKey))
            ]
            navToggleButton = toggle
            navActionButtons = actions
            navCollapsed = false

            let stack = NSStackView(views: [toggle] + actions)
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            panel.contentView = stack

            if let screen = NSScreen.main?.visibleFrame {
                let x = screen.midX - 450
                let y = screen.minY + 48
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            navPanel = panel
        }
        navPanel?.deminiaturize(nil)
        navPanel?.orderFront(nil)
    }

    @objc private func toggleFloatingNavSize() {
        guard let panel = navPanel else { return }
        navCollapsed.toggle()
        navActionButtons.forEach { $0.isHidden = navCollapsed }
        navToggleButton?.title = navCollapsed ? "+ Controls" : "−"
        var frame = panel.frame
        frame.size.width = navCollapsed ? 128 : 900
        panel.setFrame(frame, display: true, animate: true)
    }

    private func hideFloatingNav() {
        navPanel?.orderOut(nil)
    }

    @objc private func stopMirror() { process?.terminate(); process = nil; hideFloatingNav(); status.stringValue = "Mirroring stopped."; record("Mirror stopped by user") }
    @objc private func showLog() { let alert = NSAlert(); alert.messageText = "NearDoc diagnostic log"; alert.informativeText = log.joined(separator: "\n"); alert.addButton(withTitle: "Close"); alert.runModal() }
    private func record(_ text: String) { let row = "\(ISO8601DateFormatter().string(from: Date()))  \(text)"; log.append(row); if log.count > 40 { log.removeFirst() } }
}
