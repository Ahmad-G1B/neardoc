import AppKit
import UniformTypeIdentifiers

/// Floating Phone Files browser that supports true macOS Drag & Drop directly from any Android phone
/// into any Mac Finder folder, project, or app via NSFilePromiseProvider + fast USB/Wi-Fi adb pull.
final class PhoneFilesPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
    struct RemoteItem {
        let name: String
        let remotePath: String
    }

    private let folders: [(label: String, path: String)] = [
        ("All Recent Videos", "__ALL_VIDEOS__"),
        ("Camera (Photos & Videos)", "/sdcard/DCIM/Camera"),
        ("Screenshots (All Android)", "__ALL_SCREENSHOTS__"),
        ("Screen Recordings (All Android)", "__ALL_RECORDINGS__"),
        ("Movies", "/sdcard/Movies"),
        ("Downloads", "/sdcard/Download"),
        ("NearDoc Folder", "/sdcard/Download/NearDoc"),
        ("Documents", "/sdcard/Documents")
    ]

    private var panel: NSPanel!
    private var folderPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var tableView: NSTableView!
    private var pauseBtn: NSButton!
    private var stopBtn: NSButton!
    private var items: [RemoteItem] = []

    private var activePullProcess: Process?
    private var pullPaused = false
    private var pullCancelled = false

    private let activeSerialProvider: () -> String?
    private let runAdb: ([String]) throws -> String
    private let adbEnvProvider: () -> [String: String]
    private let receivedDirProvider: () -> URL
    private let workQueue = OperationQueue()

    init(
        activeSerialProvider: @escaping () -> String?,
        runAdb: @escaping ([String]) throws -> String,
        adbEnvProvider: @escaping () -> [String: String],
        receivedDirProvider: @escaping () -> URL
    ) {
        self.activeSerialProvider = activeSerialProvider
        self.runAdb = runAdb
        self.adbEnvProvider = adbEnvProvider
        self.receivedDirProvider = receivedDirProvider
        super.init()
        buildPanel()
    }

    func show() {
        panel.deminiaturize(nil)
        panel.makeKeyAndOrderFront(nil)
        reloadFiles()
    }

    private func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Phone Files — Drag & Drop to Mac (USB 3.2)"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 360, height: 340)

        let root = NSView()

        let hint = NSTextField(wrappingLabelWithString: "Drag any photo, video, or document straight into Finder, Desktop, or a project folder (supports multi-select).")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor

        folderPopup = NSPopUpButton()
        folders.forEach { folderPopup.addItem(withTitle: $0.label) }
        folderPopup.target = self
        folderPopup.action = #selector(folderChanged)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(reloadFiles))
        refreshBtn.bezelStyle = .rounded

        let saveBtn = NSButton(title: "Save to Mac", target: self, action: #selector(saveSelectedToMac))
        saveBtn.bezelStyle = .rounded

        pauseBtn = NSButton(title: "⏸ Pause", target: self, action: #selector(togglePausePull))
        pauseBtn.bezelStyle = .rounded
        pauseBtn.isEnabled = false

        stopBtn = NSButton(title: "⏹ Stop", target: self, action: #selector(stopPull))
        stopBtn.bezelStyle = .rounded
        stopBtn.isEnabled = false

        let topBar = NSStackView(views: [folderPopup, refreshBtn, saveBtn, pauseBtn, stopBtn])
        topBar.orientation = .horizontal
        topBar.spacing = 6

        tableView = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Recent Files on Phone (drag out or click Save to Mac)"
        tableView.addTableColumn(col)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 24
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        [hint, topBar, scroll, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),

            topBar.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        panel.contentView = root
        panel.center()
    }

    @objc private func folderChanged() {
        reloadFiles()
    }

    @objc func reloadFiles() {
        let idx = max(0, folderPopup.indexOfSelectedItem)
        let folder = folders[idx]
        statusLabel.stringValue = "Loading \(folder.label)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let serial = self.activeSerialProvider() else {
                DispatchQueue.main.async {
                    self.items = []
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = "Connect your Android phone over USB or Wi-Fi first."
                }
                return
            }

            let loaded: [RemoteItem]
            if folder.path == "__ALL_VIDEOS__" {
                let cmd = "find /sdcard/DCIM /sdcard/Movies /sdcard/Download /sdcard/Pictures -maxdepth 3 -type f \\( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.3gp' \\) 2>/dev/null | head -n 80"
                let output = (try? self.runAdb(["-s", serial, "shell", cmd])) ?? ""
                loaded = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("/sdcard/") }
                    .reversed()
                    .map { path in RemoteItem(name: URL(fileURLWithPath: path).lastPathComponent, remotePath: path) }
            } else if folder.path == "__ALL_SCREENSHOTS__" {
                let cmd = "find /sdcard/DCIM/Screenshots /sdcard/Pictures/Screenshots -maxdepth 2 -type f 2>/dev/null | head -n 80"
                let output = (try? self.runAdb(["-s", serial, "shell", cmd])) ?? ""
                loaded = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("/sdcard/") }
                    .reversed()
                    .map { path in RemoteItem(name: URL(fileURLWithPath: path).lastPathComponent, remotePath: path) }
            } else if folder.path == "__ALL_RECORDINGS__" {
                let cmd = "find '/sdcard/DCIM/Screen recordings' /sdcard/DCIM/ScreenRecorder /sdcard/Movies -maxdepth 2 -type f 2>/dev/null | head -n 80"
                let output = (try? self.runAdb(["-s", serial, "shell", cmd])) ?? ""
                loaded = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("/sdcard/") }
                    .reversed()
                    .map { path in RemoteItem(name: URL(fileURLWithPath: path).lastPathComponent, remotePath: path) }
            } else {
                // Quote path safely so folders with spaces (like "Screen recordings") work cleanly.
                let escaped = folder.path.replacingOccurrences(of: "'", with: "'\\''")
                let output = (try? self.runAdb(["-s", serial, "shell", "ls -1pt '\(escaped)' 2>/dev/null"])) ?? ""
                let names = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasSuffix("/") && !$0.hasPrefix(".") && !$0.hasPrefix("ls:") }
                    .prefix(60)
                loaded = names.map { RemoteItem(name: $0, remotePath: "\(folder.path)/\($0)") }
            }

            DispatchQueue.main.async {
                self.items = loaded
                self.tableView.reloadData()
                self.statusLabel.stringValue = loaded.isEmpty
                    ? "No files found in \(folder.label)."
                    : "Showing \(loaded.count) item(s) — drag to Finder or click Save to Mac."
            }
        }
    }

    @objc private func togglePausePull() {
        guard let proc = activePullProcess, proc.isRunning else { return }
        pullPaused.toggle()
        kill(proc.processIdentifier, pullPaused ? SIGSTOP : SIGCONT)
        pauseBtn.title = pullPaused ? "▶ Resume" : "⏸ Pause"
        statusLabel.stringValue = pullPaused ? "Transfer paused. Click Resume to continue." : "Resuming transfer…"
    }

    @objc private func stopPull() {
        pullCancelled = true
        if let proc = activePullProcess, proc.isRunning {
            if pullPaused { kill(proc.processIdentifier, SIGCONT) }
            proc.terminate()
        }
        pullPaused = false
        pauseBtn.title = "⏸ Pause"
        pauseBtn.isEnabled = false
        stopBtn.isEnabled = false
        statusLabel.stringValue = "Transfer stopped."
    }

    private func runPull(_ serial: String, remotePath: String, localPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.adbPath())
        proc.arguments = ["-s", serial, "pull", remotePath, localPath]
        proc.environment = adbEnvProvider()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        activePullProcess = proc
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        activePullProcess = nil
        if pullCancelled {
            try? FileManager.default.removeItem(atPath: localPath)
            throw NSError(domain: "NearDoc", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer stopped by user."])
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8) ?? "adb pull failed"
            throw NSError(domain: "NearDoc", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    @objc private func saveSelectedToMac() {
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else {
            statusLabel.stringValue = "Select one or more files first (or drag any row into Finder)."
            return
        }
        let chosen = rows.compactMap { $0 < items.count ? items[$0] : nil }
        pullCancelled = false
        pullPaused = false
        pauseBtn.title = "⏸ Pause"
        pauseBtn.isEnabled = true
        stopBtn.isEnabled = true
        statusLabel.stringValue = "Copying \(chosen.count) file(s) to Downloads/NearDoc…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let serial = self.activeSerialProvider() else { return }
            var savedURLs: [URL] = []
            do {
                for (i, item) in chosen.enumerated() {
                    if self.pullCancelled { break }
                    DispatchQueue.main.async {
                        self.statusLabel.stringValue = "Copying (\(i + 1)/\(chosen.count)): \(item.name)…"
                    }
                    let dest = self.receivedDirProvider().appendingPathComponent(item.name)
                    try self.runPull(serial, remotePath: item.remotePath, localPath: dest.path)
                    savedURLs.append(dest)
                }
                DispatchQueue.main.async {
                    self.pauseBtn.title = "⏸ Pause"
                    self.pauseBtn.isEnabled = false
                    self.stopBtn.isEnabled = false
                    if !self.pullCancelled {
                        self.statusLabel.stringValue = "Saved \(savedURLs.count) file(s) to Downloads/NearDoc."
                        if !savedURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(savedURLs) }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.pauseBtn.title = "⏸ Pause"
                    self.pauseBtn.isEnabled = false
                    self.stopBtn.isEnabled = false
                    self.statusLabel.stringValue = self.pullCancelled ? "Transfer stopped." : "Copy failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - NSTableViewDataSource & Drag-Out Promise

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf)
            v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()
        cell.textField?.stringValue = items[row].name
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = items[row]
        let ext = URL(fileURLWithPath: item.name).pathExtension
        let fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = item
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? RemoteItem)?.name ?? "phone-file"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        workQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let item = filePromiseProvider.userInfo as? RemoteItem else {
            completionHandler(NSError(domain: "NearDoc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing file info"]))
            return
        }
        guard let serial = activeSerialProvider() else {
            completionHandler(NSError(domain: "NearDoc", code: 2, userInfo: [NSLocalizedDescriptionKey: "Phone is not connected"]))
            return
        }
        DispatchQueue.main.async { self.statusLabel.stringValue = "Pulling \(item.name) to \(url.deletingLastPathComponent().lastPathComponent)…" }
        do {
            _ = try runAdb(["-s", serial, "pull", item.remotePath, url.path])
            DispatchQueue.main.async { self.statusLabel.stringValue = "Dropped \(item.name) into Mac folder." }
            completionHandler(nil)
        } catch {
            DispatchQueue.main.async { self.statusLabel.stringValue = "Drop failed: \(error.localizedDescription)" }
            completionHandler(error)
        }
    }
}
