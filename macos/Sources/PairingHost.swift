import Foundation
import AppKit
import Network
import CryptoKit

struct QueuedMacFile {
    let id: String
    let url: URL
    let name: String
    let size: Int64
}

/// Persistent local-network server for NearDoc.
/// Handles one-time QR pairing (HMAC-SHA256), high-speed streaming file transfer, and clipboard sync.
final class PairingHost {
    private static let tokenKey = "linkbridge.paired.token"
    private static let deviceNameKey = "linkbridge.paired.deviceName"
    private static let maxFileBytes: Int64 = 20 * 1024 * 1024 * 1024 // 20 GB

    private let ioQueue = DispatchQueue(label: "com.linkbridge.net", qos: .userInitiated)
    private var listener: NWListener?
    private var activePort: UInt16 = 0
    private var hostAddress = ""
    private var pairSecret = ""
    private var pairingCode = ""

    private var sessionToken: String
    private(set) var pairedDeviceName: String

    private var queuedFiles: [QueuedMacFile] = []
    private var queuedClipboard: (id: String, text: String)?
    private var activeTransfer: BufferedConnection?
    private(set) var isTransferPaused = false

    var onStatus: ((String) -> Void)?
    var onPairingCode: ((String?) -> Void)?
    var onPairedStateChanged: ((Bool, String) -> Void)?
    var onFileReceived: ((URL) -> Void)?
    var onNotificationReceived: ((String, String, String, String, Bool) -> Void)?
    var onTransferStateChanged: ((Bool, Bool) -> Void)?

    var isPaired: Bool { !sessionToken.isEmpty }

    init() {
        let defaults = UserDefaults.standard
        self.sessionToken = defaults.string(forKey: Self.tokenKey) ?? ""
        self.pairedDeviceName = defaults.string(forKey: Self.deviceNameKey) ?? ""
    }

    func startIfPaired() {
        guard isPaired else { return }
        try? ensureListening(showQR: false)
    }

    func beginPairing() throws {
        pairSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try ensureListening(showQR: true)
    }

    func unpair() {
        sessionToken = ""
        pairedDeviceName = ""
        pairSecret = ""
        pairingCode = ""
        queuedFiles.removeAll()
        queuedClipboard = nil
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
        listener?.cancel()
        listener = nil
        activePort = 0
        onPairingCode?(nil)
        onPairedStateChanged?(false, "")
        onStatus?("Unpaired from phone. Click Pair phone with QR to link again.")
    }

    func togglePauseTransfer() -> Bool {
        guard let transfer = activeTransfer else { return false }
        isTransferPaused.toggle()
        let paused = isTransferPaused
        ioQueue.async { transfer.setPaused(paused) }
        DispatchQueue.main.async { [weak self] in self?.onTransferStateChanged?(true, paused) }
        notifyStatus(paused ? "Wi-Fi file transfer paused." : "Resuming Wi-Fi file transfer…")
        return paused
    }

    func stopActiveTransfer() {
        guard let transfer = activeTransfer else { return }
        isTransferPaused = false
        activeTransfer = nil
        ioQueue.async { transfer.cancelTransfer() }
        DispatchQueue.main.async { [weak self] in self?.onTransferStateChanged?(false, false) }
        notifyStatus("Wi-Fi file transfer stopped.")
    }

    func stop() {
        stopActiveTransfer()
        listener?.cancel()
        listener = nil
        activePort = 0
        pairSecret = ""
        pairingCode = ""
        onPairingCode?(nil)
        onStatus?("Local bridge listener stopped.")
    }

    func queueFilesForPhone(_ urls: [URL]) -> Int {
        guard isPaired else { return 0 }
        try? ensureListening(showQR: false)
        var added = 0
        for url in urls {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let sizeNum = attrs[.size] as? NSNumber else { continue }
            let item = QueuedMacFile(
                id: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                url: url,
                name: url.lastPathComponent,
                size: sizeNum.int64Value
            )
            queuedFiles.append(item)
            added += 1
        }
        return added
    }

    func queueClipboardForPhone(_ text: String) -> Bool {
        guard isPaired, !text.isEmpty else { return false }
        try? ensureListening(showQR: false)
        queuedClipboard = (id: UUID().uuidString.replacingOccurrences(of: "-", with: ""), text: text)
        return true
    }

    func receivedFilesDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let folder = downloads.appendingPathComponent("NearDoc", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func ensureListening(showQR: Bool) throws {
        guard let address = localIPv4() else { throw PairingError.noLocalAddress }
        hostAddress = address

        if listener != nil, activePort > 0 {
            if showQR { emitQRCode() }
            return
        }

        let newListener: NWListener
        if let preferredPort = NWEndpoint.Port(rawValue: 39874),
           let fixed = try? NWListener(using: .tcp, on: preferredPort) {
            newListener = fixed
        } else {
            newListener = try NWListener(using: .tcp)
        }

        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = newListener.port else {
                    self.notifyStatus("Local bridge listener did not provide a port.")
                    return
                }
                self.activePort = port.rawValue
                if showQR && !self.pairSecret.isEmpty {
                    self.emitQRCode()
                } else if self.isPaired {
                    let name = self.pairedDeviceName.isEmpty ? "your phone" : self.pairedDeviceName
                    self.notifyStatus("Ready for \(name) on \(self.hostAddress):\(self.activePort).")
                }
            case .failed(let error):
                self.listener?.cancel()
                self.listener = nil
                self.activePort = 0
                self.notifyStatus("Local bridge listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        newListener.start(queue: ioQueue)
        if showQR {
            notifyStatus("Starting local pairing listener on \(hostAddress)…")
        }
    }

    private func emitQRCode() {
        guard activePort > 0, !pairSecret.isEmpty else { return }
        pairingCode = "LB1|\(hostAddress)|\(activePort)|\(pairSecret)"
        notifyStatus("Scan this QR code with NearDoc on your phone (\(hostAddress):\(activePort)).")
        let codeCopy = pairingCode
        DispatchQueue.main.async { [weak self] in self?.onPairingCode?(codeCopy) }
    }

    private func notifyStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    // MARK: - Connection Handling (runs on background ioQueue so large transfers never block UI)

    private func handle(_ connection: NWConnection) {
        let reader = BufferedConnection(connection: connection)
        connection.start(queue: ioQueue)
        reader.readLine { [weak self] line, leftover in
            guard let self, let line else {
                connection.cancel()
                return
            }
            self.dispatch(line: line, leftover: leftover, reader: reader)
        }
    }

    private func dispatch(line: String, leftover: Data, reader: BufferedConnection) {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        guard let command = fields.first else {
            reader.sendAndClose("ERR empty\n")
            return
        }

        switch command {
        case "LB1":
            handlePairHandshake(fields: fields, reader: reader)
        case "PING":
            guard fields.count == 3, verifySession(fields[2], message: "PING:\(fields[1])") else {
                reader.sendAndClose("DENIED\n")
                return
            }
            let macName = Host.current().localizedName ?? "Mac"
            reader.sendAndClose("PONG \(b64Encode(macName))\n")
        case "CLIP_PUSH":
            handleClipPush(fields: fields, leftover: leftover, reader: reader)
        case "CLIP_PULL":
            guard fields.count == 3, verifySession(fields[2], message: "CLIP_PULL:\(fields[1])") else {
                reader.sendAndClose("DENIED\n")
                return
            }
            var text = ""
            DispatchQueue.main.sync {
                text = NSPasteboard.general.string(forType: .string) ?? ""
            }
            let payload = Data(text.utf8)
            var response = Data("OK \(payload.count)\n".utf8)
            response.append(payload)
            reader.sendAndClose(response)
            notifyStatus("Sent Mac clipboard (\(payload.count) bytes) to \(displayPhoneName()).")
        case "FILE_PUSH":
            handleFilePush(fields: fields, leftover: leftover, reader: reader)
        case "PENDING":
            guard fields.count == 3, verifySession(fields[2], message: "PENDING:\(fields[1])") else {
                reader.sendAndClose("DENIED\n")
                return
            }
            if let clip = queuedClipboard {
                queuedClipboard = nil
                let payload = Data(clip.text.utf8)
                var response = Data("CLIP \(clip.id) \(payload.count)\n".utf8)
                response.append(payload)
                reader.sendAndClose(response)
                notifyStatus("Synced Mac clipboard to \(displayPhoneName()).")
            } else if let file = queuedFiles.first {
                reader.sendAndClose("FILE \(file.id) \(b64Encode(file.name)) \(file.size)\n")
            } else {
                reader.sendAndClose("NONE\n")
            }
        case "FILE_PULL":
            handleFilePull(fields: fields, reader: reader)
        case "NOTIF_PUSH":
            handleNotifPush(fields: fields, reader: reader)
        default:
            reader.sendAndClose("ERR unknown\n")
        }
    }

    private func handleNotifPush(fields: [String], reader: BufferedConnection) {
        guard fields.count >= 6,
              verifySession(fields[2], message: "NOTIF_PUSH:\(fields[1]):\(fields[3]):\(fields[4]):\(fields[5])"),
              let appName = b64Decode(fields[3]),
              let title = b64Decode(fields[4]),
              let body = b64Decode(fields[5]) else {
            reader.sendAndClose("DENIED\n")
            return
        }
        let key = fields.count >= 7 ? (b64Decode(fields[6]) ?? "") : ""
        let isCall = fields.count >= 8 && fields[7] == "CALL"
        reader.sendAndClose("OK\n")
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationReceived?(appName, title, body, key, isCall)
        }
    }

    private func handlePairHandshake(fields: [String], reader: BufferedConnection) {
        guard !pairSecret.isEmpty,
              fields.count >= 3,
              hmac(secret: pairSecret, value: "client:\(fields[1])") == fields[2] else {
            reader.sendAndClose("DENIED\n")
            return
        }

        let phoneName = fields.count >= 4 ? (b64Decode(fields[3]) ?? "Android Phone") : "Android Phone"
        let serverNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let serverProof = hmac(secret: pairSecret, value: "server:\(fields[1]):\(serverNonce)")
        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "") +
                       UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let macName = Host.current().localizedName ?? "Mac"

        sessionToken = newToken
        pairedDeviceName = phoneName
        pairSecret = ""
        pairingCode = ""

        UserDefaults.standard.set(newToken, forKey: Self.tokenKey)
        UserDefaults.standard.set(phoneName, forKey: Self.deviceNameKey)

        let reply = "OK \(serverNonce) \(serverProof) \(newToken) \(b64Encode(macName))\n"
        reader.sendAndClose(reply)
        DispatchQueue.main.async { [weak self] in
            self?.onPairingCode?(nil)
            self?.onPairedStateChanged?(true, phoneName)
        }
        notifyStatus("Paired with \(phoneName) on \(hostAddress):\(activePort). Ready for files and clipboard.")
    }

    private func handleClipPush(fields: [String], leftover: Data, reader: BufferedConnection) {
        guard fields.count == 4,
              let byteLen = Int(fields[3]), byteLen >= 0, byteLen <= 1_048_576,
              verifySession(fields[2], message: "CLIP_PUSH:\(fields[1]):\(byteLen)") else {
            reader.sendAndClose("DENIED\n")
            return
        }
        reader.readExact(byteLen, initial: leftover) { [weak self] data in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                reader.sendAndClose("ERR read\n")
                return
            }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            reader.sendAndClose("OK\n")
            let preview = text.count > 48 ? String(text.prefix(48)) + "…" : text
            self.notifyStatus("Received clipboard from \(self.displayPhoneName()): \"\(preview)\"")
        }
    }

    private func handleFilePush(fields: [String], leftover: Data, reader: BufferedConnection) {
        guard fields.count == 5,
              let rawName = b64Decode(fields[3]),
              let byteLen = Int64(fields[4]), byteLen >= 0, byteLen <= Self.maxFileBytes,
              verifySession(fields[2], message: "FILE_PUSH:\(fields[1]):\(fields[3]):\(byteLen)") else {
            reader.sendAndClose("DENIED\n")
            return
        }

        let destURL = uniqueDestinationURL(for: rawName)
        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            reader.sendAndClose("ERR file\n")
            return
        }

        let totalMB = String(format: "%.1f", Double(byteLen) / (1024.0 * 1024.0))
        activeTransfer = reader
        isTransferPaused = false
        DispatchQueue.main.async { [weak self] in self?.onTransferStateChanged?(true, false) }
        notifyStatus("Receiving \(destURL.lastPathComponent) (\(totalMB) MB) from \(displayPhoneName())…")
        var lastReportTime = Date.distantPast

        reader.streamExact(
            byteLen,
            initial: leftover,
            to: handle,
            onProgress: { [weak self] received in
                guard let self else { return }
                let now = Date()
                if now.timeIntervalSince(lastReportTime) >= 0.5 {
                    lastReportTime = now
                    let recMB = String(format: "%.1f", Double(received) / (1024.0 * 1024.0))
                    let pct = byteLen > 0 ? Int((Double(received) / Double(byteLen)) * 100.0) : 100
                    self.notifyStatus("Receiving \(destURL.lastPathComponent): \(recMB) / \(totalMB) MB (\(pct)%)…")
                }
            },
            completion: { [weak self] success in
                try? handle.synchronize()
                try? handle.close()
                guard let self else { reader.close(); return }
                self.activeTransfer = nil
                self.isTransferPaused = false
                DispatchQueue.main.async { self.onTransferStateChanged?(false, false) }
                if success {
                    reader.sendAndClose("OK\n")
                    self.notifyStatus("Saved \(destURL.lastPathComponent) (\(totalMB) MB) to Downloads/NearDoc.")
                    DispatchQueue.main.async { self.onFileReceived?(destURL) }
                } else {
                    try? FileManager.default.removeItem(at: destURL)
                    reader.sendAndClose("ERR transfer\n")
                    self.notifyStatus("File transfer stopped or failed for \(destURL.lastPathComponent).")
                }
            }
        )
    }

    private func handleFilePull(fields: [String], reader: BufferedConnection) {
        guard fields.count == 4,
              verifySession(fields[2], message: "FILE_PULL:\(fields[1]):\(fields[3])"),
              let index = queuedFiles.firstIndex(where: { $0.id == fields[3] }) else {
            reader.sendAndClose("DENIED\n")
            return
        }
        let item = queuedFiles.remove(at: index)
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            reader.sendAndClose("ERR missing\n")
            notifyStatus("Could not read \(item.name) to send to phone.")
            return
        }
        notifyStatus("Sending \(item.name) to \(displayPhoneName())…")
        reader.sendHeaderAndStreamFile(header: Data("OK \(item.size)\n".utf8), fileHandle: handle) { [weak self] ok in
            try? handle.close()
            guard let self else { return }
            if ok {
                self.notifyStatus("Sent \(item.name) to \(self.displayPhoneName()).")
            } else {
                self.notifyStatus("Failed sending \(item.name) to \(self.displayPhoneName()).")
            }
        }
    }

    // MARK: - Helpers

    private func displayPhoneName() -> String {
        pairedDeviceName.isEmpty ? "your phone" : pairedDeviceName
    }

    private func verifySession(_ proof: String, message: String) -> Bool {
        guard !sessionToken.isEmpty else { return false }
        return hmac(secret: sessionToken, value: message) == proof
    }

    private func hmac(secret: String, value: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func b64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func b64Decode(_ value: String) -> String? {
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func uniqueDestinationURL(for rawName: String) -> URL {
        let sanitized = URL(fileURLWithPath: rawName).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let finalName = sanitized.isEmpty ? "received-file" : sanitized
        let folder = receivedFilesDirectory()
        var candidate = folder.appendingPathComponent(finalName)
        let ext = candidate.pathExtension
        let stem = ext.isEmpty ? finalName : String(finalName.dropLast(ext.count + 1))
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }
}

/// Incremental TCP reader/writer for NWConnection supporting multi-GB streaming.
private final class BufferedConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var paused = false
    private var cancelled = false
    private var resumeWork: (() -> Void)?

    func setPaused(_ value: Bool) {
        paused = value
        if !paused, let work = resumeWork {
            resumeWork = nil
            work()
        }
    }

    func cancelTransfer() {
        cancelled = true
        paused = false
        resumeWork = nil
        connection.cancel()
    }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func readLine(completion: @escaping (String?, Data) -> Void) {
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            let leftover = Data(buffer[(newlineIndex + 1)...])
            buffer.removeAll()
            completion(String(data: lineData, encoding: .utf8), leftover)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > 16_384 {
                    completion(nil, Data())
                    return
                }
                if self.buffer.contains(0x0A) {
                    self.readLine(completion: completion)
                    return
                }
            }
            if isComplete || error != nil {
                completion(nil, Data())
            } else {
                self.readLine(completion: completion)
            }
        }
    }

    func readExact(_ count: Int, initial: Data, completion: @escaping (Data?) -> Void) {
        var collected = initial
        if collected.count >= count {
            completion(Data(collected.prefix(count)))
            return
        }
        func pump() {
            let remaining = count - collected.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 262_144)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    collected.append(data)
                    if collected.count >= count {
                        completion(Data(collected.prefix(count)))
                        return
                    }
                }
                if isComplete || error != nil {
                    completion(nil)
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    func streamExact(
        _ totalBytes: Int64,
        initial: Data,
        to fileHandle: FileHandle,
        onProgress: @escaping (Int64) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        var received: Int64 = 0
        var remaining = totalBytes
        var writeBuffer = Data()
        writeBuffer.reserveCapacity(2 * 1024 * 1024)
        let flushThreshold = 1_048_576 // Flush to disk every 1 MB instead of every TCP packet

        func flushBuffer() -> Bool {
            guard !writeBuffer.isEmpty else { return true }
            do {
                try fileHandle.write(contentsOf: writeBuffer)
                writeBuffer.removeAll(keepingCapacity: true)
                return true
            } catch {
                return false
            }
        }

        if !initial.isEmpty {
            let toWrite = initial.prefix(Int(min(Int64(initial.count), remaining)))
            writeBuffer.append(toWrite)
            received += Int64(toWrite.count)
            remaining -= Int64(toWrite.count)
            onProgress(received)
        }
        if remaining <= 0 {
            completion(flushBuffer())
            return
        }

        func pump() {
            if self.cancelled { completion(false); return }
            if self.paused {
                self.resumeWork = { pump() }
                return
            }
            let maxLen = Int(min(remaining, 524_288))
            let minLen = Int(min(remaining, 65_536))
            connection.receive(minimumIncompleteLength: minLen, maximumLength: maxLen) { data, _, isComplete, error in
                if self.cancelled { completion(false); return }
                if let data, !data.isEmpty {
                    let toWrite = data.prefix(Int(min(Int64(data.count), remaining)))
                    writeBuffer.append(toWrite)
                    received += Int64(toWrite.count)
                    remaining -= Int64(toWrite.count)
                    if writeBuffer.count >= flushThreshold || remaining <= 0 {
                        guard flushBuffer() else {
                            completion(false)
                            return
                        }
                    }
                    onProgress(received)
                    if remaining <= 0 {
                        completion(true)
                        return
                    }
                }
                if isComplete || error != nil {
                    completion(false)
                } else {
                    pump()
                }
            }
        }
        pump()
    }

    func sendHeaderAndStreamFile(header: Data, fileHandle: FileHandle, completion: @escaping (Bool) -> Void) {
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.connection.cancel()
                completion(false)
                return
            }
            func sendNextChunk() {
                let chunk = fileHandle.readData(ofLength: 262_144)
                if chunk.isEmpty {
                    self.connection.cancel()
                    completion(true)
                    return
                }
                self.connection.send(content: chunk, completion: .contentProcessed { sendErr in
                    if sendErr != nil {
                        self.connection.cancel()
                        completion(false)
                    } else {
                        sendNextChunk()
                    }
                })
            }
            sendNextChunk()
        })
    }

    func sendAndClose(_ text: String) {
        sendAndClose(Data(text.utf8))
    }

    func sendAndClose(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    func close() {
        connection.cancel()
    }
}

private enum PairingError: LocalizedError {
    case noLocalAddress
    var errorDescription: String? {
        "No local Wi-Fi or Ethernet IPv4 address found on this Mac."
    }
}

private func localIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let start = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }

    var fallback: String?
    for item in sequence(first: start, next: { $0.pointee.ifa_next }) {
        let interface = item.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(interface.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: interface.ifa_name)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let value = String(cString: host)
        guard !value.hasPrefix("169.254.") else { continue }
        if name == "en0" || name == "en1" { return value }
        if fallback == nil && (value.hasPrefix("192.168.") || value.hasPrefix("10.") || value.hasPrefix("172.")) {
            fallback = value
        }
    }
    return fallback
}
