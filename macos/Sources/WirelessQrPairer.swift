import Foundation

/// Implements Android 11+ Wireless Debugging QR code pairing (`WIFI:T:ADB;S:...;P:...;;`)
/// using macOS Bonjour (NetServiceBrowser) + `adb mdns services` fallback.
final class WirelessQrPairer: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var pollTimer: Timer?
    private var timeoutTimer: Timer?

    private var serviceName = ""
    private var password = ""
    private var pairingTriggered = false

    private let runAdb: ([String]) throws -> String
    var onStatus: ((String) -> Void)?
    var onQrPayload: ((String?) -> Void)?
    var onPaired: (() -> Void)?

    init(runAdb: @escaping ([String]) throws -> String) {
        self.runAdb = runAdb
        super.init()
    }

    func start() {
        stop(clearQR: false)
        pairingTriggered = false
        serviceName = "bridge-adb-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        password = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))

        let payload = "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
        onQrPayload?(payload)
        onStatus?("On your Android phone: Settings → Developer options → Wireless debugging → Pair device with QR code, then scan this QR.")

        // Ensure adb server is running so mdns discovery is active too.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.runAdb(["start-server"])
        }

        let newBrowser = NetServiceBrowser()
        newBrowser.delegate = self
        newBrowser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")
        browser = newBrowser

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollAdbMdns()
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            guard let self, !self.pairingTriggered else { return }
            self.stop(clearQR: true)
            self.onStatus?("Wireless QR pairing timed out. If your router blocks mDNS, use Pair Wi-Fi (Code) instead.")
        }
    }

    func stop(clearQR: Bool = true) {
        browser?.stop()
        browser = nil
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        if clearQR { onQrPayload?(nil) }
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !pairingTriggered else { return }
        // Some Android OEMs advertise their own service name instead of the QR's S: token, so resolve any pairing service.
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 8.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !pairingTriggered, let addresses = sender.addresses else { return }
        for addrData in addresses {
            if let ip = ipv4String(from: addrData), sender.port > 0 {
                triggerPair(endpoint: "\(ip):\(sender.port)")
                return
            }
        }
    }

    // MARK: - adb mdns fallback

    private func pollAdbMdns() {
        guard !pairingTriggered else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.pairingTriggered else { return }
            guard let output = try? self.runAdb(["mdns", "services"]) else { return }
            for line in output.components(separatedBy: .newlines) {
                guard line.contains("_adb-tls-pairing._tcp") else { continue }
                if let match = line.range(of: "\\d{1,3}(?:\\.\\d{1,3}){3}:\\d+", options: .regularExpression) {
                    let endpoint = String(line[match])
                    DispatchQueue.main.async { self.triggerPair(endpoint: endpoint) }
                    return
                }
            }
        }
    }

    private func triggerPair(endpoint: String) {
        guard !pairingTriggered else { return }
        pairingTriggered = true
        let pwd = password
        stop(clearQR: false)
        onStatus?("Phone scanned QR! Pairing wirelessly with \(endpoint)…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let output = try self.runAdb(["pair", endpoint, pwd])
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.onQrPayload?(nil)
                    if trimmed.lowercased().contains("successfully paired") {
                        self.onStatus?("Wireless Debugging paired via QR! Connecting over Wi-Fi…")
                        self.onPaired?()
                    } else {
                        self.onStatus?("Wireless QR pairing response: \(trimmed)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.onQrPayload?(nil)
                    self.onStatus?("Wireless QR pairing failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func ipv4String(from addressData: Data) -> String? {
        addressData.withUnsafeBytes { rawBuffer -> String? in
            guard let sockaddrPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                  sockaddrPtr.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let res = getnameinfo(sockaddrPtr, socklen_t(addressData.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return res == 0 ? String(cString: host) : nil
        }
    }
}
