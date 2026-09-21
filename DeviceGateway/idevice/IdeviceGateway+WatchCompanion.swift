//
//  IdeviceGateway+WatchCompanion.swift
//  DeviceGateway
//
//  Install embedded Watch apps via the companion proxy (isideload PR #12 flow,
//  on-device). See docs/issue-229-fix.md in SideStore.
//
//  Flow: companion_proxy (RSD service on the phone) -> get_device_registry
//        -> start_forwarding_service_port(62078) -> TCP connect to forwarded
//        port -> lockdownd_new -> lockdownd_pair (trust prompt on watch)
//        -> lockdownd_start_session
//        -> per watch app:
//             start_service(installation_proxy) -> forward -> uninstall(bundleId)
//             start_service(streaming_zip_conduit) -> forward -> stream .app
//
//  The streaming_zip_conduit wire format is a length-prefixed XML plist
//  "InitTransfer" header, then a raw stored (uncompressed) zip stream of
//  Payload/<App>.app/**, terminated by a bare central-directory signature,
//  after which watchOS replies with length-prefixed plist progress frames.
//

import Foundation
import IDevice
import DeviceGatewayAPI

public struct WatchCompanionSpikeResult: Sendable {
    public var watchUDIDs: [String] = []
    public var forwardedPort: UInt16 = 0
    public var connectedVia: String = ""
    public var watchProductType: String = ""
    public var watchOSVersion: String = ""
    public var paired: Bool = false
    public var sessionStarted: Bool = false
    public var pairingRecord: Data? = nil
    public var log: [String] = []

    public var summary: String {
        var lines = log
        lines.append("---")
        lines.append("watches=\(watchUDIDs.count) port=\(forwardedPort) via=\(connectedVia)")
        lines.append("product=\(watchProductType) os=\(watchOSVersion)")
        lines.append("paired=\(paired) session=\(sessionStarted) record=\(pairingRecord?.count ?? 0)B")
        return lines.joined(separator: "\n")
    }
}

/// A paired, session-established lockdownd connection to the watch, plus the
/// context needed to open further watch services through the companion proxy.
private struct WatchLockdownSession {
    // NOTE: lockdownd_new() CONSUMES the IdeviceHandle (Box::from_raw in the FFI),
    // so the socket is owned by `lockdown` and must not be freed separately.
    let lockdown: OpaquePointer        // LockdowndClientHandle (owned; owns the socket)
    let pairing: OpaquePointer         // IdevicePairingFile (owned)
    let legacy: Bool
    let connectedHost: String

    func free() {
        lockdownd_client_free(lockdown)
        idevice_pairing_file_free(pairing)
    }
}

extension IdeviceGateway {

    private static let watchLockdownPort: UInt16 = 62078
    private static let watchInstallProxyService = "com.apple.mobile.installation_proxy"
    private static let watchZipConduitService = "com.apple.streaming_zip_conduit"
    private static let forwardConnectAttempts = 20
    private static let forwardConnectDelay: TimeInterval = 0.05

    // MARK: - Public API (DeviceGatewayAPI)

    /// DeviceGatewayAPI conformance: run the spike synchronously off the main thread.
    public func watchCompanionProbe(progress: (@Sendable (String) -> Void)?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.watchCompanionSpike(progress: progress)
                    cont.resume(returning: result.summary)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Install already-signed Watch app bundles (local paths on the phone) onto
    /// the paired watch via companion_proxy + streaming_zip_conduit.
    public func installWatchApps(_ watchAppURLs: [URL], progress: (@Sendable (String) -> Void)?) async throws {
        guard !watchAppURLs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.syncInstallWatchApps(watchAppURLs, progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Spike (diagnostic)

    /// Spike: prove the phone can reach its paired watch's lockdownd through
    /// companion_proxy over SideStore's loopback VPN transport, and complete
    /// a pairing handshake (trust prompt appears on the watch).
    public func watchCompanionSpike(progress: (@Sendable (String) -> Void)? = nil) throws -> WatchCompanionSpikeResult {
        var result = WatchCompanionSpikeResult()
        func step(_ s: String) {
            result.log.append(s)
            progress?(s)
            debugLog("[WatchCompanion] \(s)")
        }

        let session = try openWatchLockdownSession(step: step, result: &result)
        defer { session.free() }

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: UInt = 0
        if idevice_pairing_file_serialize(session.pairing, &data, &size) == nil, let data {
            result.pairingRecord = Data(bytes: data, count: Int(size))
            idevice_data_free(data, size)
        }
        step("12: spike complete")
        return result
    }

    // MARK: - Install

    private func syncInstallWatchApps(_ watchAppURLs: [URL], progress: (@Sendable (String) -> Void)?) throws {
        var scratch = WatchCompanionSpikeResult()
        func step(_ s: String) {
            progress?(s)
            debugLog("[WatchInstall] \(s)")
        }

        let session = try openWatchLockdownSession(step: step, result: &scratch)
        defer {
            session.free()
            stopForwarding(Self.watchLockdownPort, step: step)
        }

        for appURL in watchAppURLs {
            let infoURL = appURL.appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: infoURL),
                  let bundleID = info["CFBundleIdentifier"] as? String else {
                throw IdeviceGatewayError(.serviceError, reason: "Watch app at \(appURL.lastPathComponent) has no CFBundleIdentifier")
            }
            step("W: installing \(bundleID) (\(appURL.lastPathComponent))")
            try removeExistingWatchApp(bundleID: bundleID, session: session, step: step)
            try streamWatchApp(at: appURL, session: session, step: step)
            step("W: \(bundleID) installed on watch")
        }
    }

    // MARK: - Shared: companion proxy + lockdown

    private func companionProxy<T>(_ label: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try performWithService(
            connect: { adapter, handshake, client in
                companion_proxy_connect_rsd(adapter, handshake, client)
            },
            cleanup: { client in
                if let client { companion_proxy_client_free(client) }
            },
            serviceName: "companion_proxy(\(label))",
            action: body
        )
    }

    private func forwardWatchPort(_ remotePort: UInt16, label: String) throws -> UInt16 {
        try companionProxy("forward:\(label)") { client in
            var port: UInt16 = 0
            if let err = companion_proxy_start_forwarding_service_port(client, remotePort, &port) {
                let msg = self.getErrorMessage(from: err)
                self.safeFreeError(err)
                throw IdeviceGatewayError(.serviceError, reason: "start_forwarding(\(remotePort)) for \(label) failed: \(msg)")
            }
            return port
        }
    }

    private func stopForwarding(_ remotePort: UInt16, step: (String) -> Void) {
        do {
            try companionProxy("stop") { client in
                if let err = companion_proxy_stop_forwarding_service_port(client, remotePort) {
                    let msg = self.getErrorMessage(from: err)
                    self.safeFreeError(err)
                    step("W: stop_forwarding(\(remotePort)) failed (non-fatal): \(msg)")
                }
            }
        } catch {
            step("W: could not reopen companion_proxy to stop forwarding \(remotePort) (non-fatal): \(error)")
        }
    }

    /// Connect to a port that companion_proxy is forwarding to the watch.
    ///
    /// Build6 finding: from ON the phone, the forwarded port is NOT reachable
    /// via a plain TCP socket on 127.0.0.1 or the tunnel peer IP (ECONNREFUSED
    /// on both) — companion_proxy binds it on the device side of the RSD
    /// tunnel. isideload gets away with `device_provider.connect(port)` because
    /// its provider *is* the tunnel. So: open the port through our RSD adapter
    /// and wrap the stream as an Idevice. Falls back to TCP loopback only if
    /// the adapter path errors, to keep the old diagnostic signal.
    private func connectForwardedPort(_ localPort: UInt16, label: String, step: (String) -> Void) throws -> (OpaquePointer, String) {
        var lastErrMsg = "no attempts"
        for attempt in 1...Self.forwardConnectAttempts {
            do {
                let dev = try connectViaAdapter(port: localPort, label: "watch-\(label)")
                if attempt > 1 { step("W: \(label) connected via RSD adapter :\(localPort) after \(attempt) attempts") }
                return (dev, "rsd-adapter")
            } catch {
                lastErrMsg = "\(error)"
                Thread.sleep(forTimeInterval: Self.forwardConnectDelay)
            }
        }
        step("W: RSD adapter connect to :\(localPort) failed (\(lastErrMsg)); trying TCP loopback…")

        var dev: OpaquePointer? = nil
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let err = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                idevice_new_tcp_socket(sptr, socklen_t(MemoryLayout<sockaddr_in>.size), "watch-\(label)", &dev)
            }
        }
        if err == nil, let dev { return (dev, "127.0.0.1") }
        if let err { lastErrMsg = getErrorMessage(from: err); safeFreeError(err) }
        throw IdeviceGatewayError(.serviceError, reason: "connect to forwarded watch \(label) port \(localPort) failed via RSD adapter and loopback: \(lastErrMsg)")
    }

    private func openWatchLockdownSession(step: (String) -> Void, result: inout WatchCompanionSpikeResult) throws -> WatchLockdownSession {
        // ── 1. companion_proxy registry ─────────────────────────────────────
        step("1: connecting companion_proxy over RSD…")
        let udids: [String] = try companionProxy("registry") { client in
            var udidsPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var count: UInt = 0
            if let err = companion_proxy_get_device_registry(client, &udidsPtr, &count) {
                let msg = self.getErrorMessage(from: err)
                self.safeFreeError(err)
                throw IdeviceGatewayError(.serviceError, reason: "get_device_registry failed: \(msg)")
            }
            var out: [String] = []
            if let udidsPtr {
                for i in 0..<Int(count) {
                    if let p = udidsPtr[i] {
                        out.append(String(cString: p))
                        idevice_string_free(p)
                    }
                }
                idevice_outer_slice_free(UnsafeMutableRawPointer(udidsPtr), UInt(count))
            }
            return out
        }
        result.watchUDIDs = udids
        step("2: device registry: \(udids.isEmpty ? "EMPTY" : udids.joined(separator: ", "))")
        guard !udids.isEmpty else {
            throw IdeviceGatewayError(.serviceError, reason: "No paired watch in companion registry")
        }

        // ── 2. forward watch lockdownd ──────────────────────────────────────
        step("3: forwarding watch lockdown port \(Self.watchLockdownPort)…")
        let localPort = try forwardWatchPort(Self.watchLockdownPort, label: "lockdown")
        result.forwardedPort = localPort
        step("4: forwarded to local port \(localPort)")

        // ── 3. TCP connect ──────────────────────────────────────────────────
        step("5: TCP connect to forwarded lockdown…")
        let (watchDevice, host) = try connectForwardedPort(localPort, label: "lockdown", step: step)
        result.connectedVia = host
        step("6: TCP connected via \(host)")

        // ── 4. lockdownd handshake + pair ───────────────────────────────────
        // lockdownd_new consumes `watchDevice` on success AND on failure paths
        // past the null check (Box::from_raw happens before connect), so never
        // idevice_free it after this call.
        var lockdown: OpaquePointer? = nil
        if let err = lockdownd_new(watchDevice, &lockdown) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_new(watch) failed: \(msg)")
        }
        guard let lockdown else {
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_new(watch) returned nil client")
        }
        var lockdownOwned = true
        defer { if lockdownOwned { lockdownd_client_free(lockdown) } }
        step("7: watch lockdownd client created")

        var valPlist: plist_t? = nil
        if lockdownd_get_value(lockdown, "ProductType", nil, &valPlist) == nil, let vp = valPlist {
            result.watchProductType = getRustPlistString(vp) ?? ""
            safeFreePlist(vp)
        }
        valPlist = nil
        if lockdownd_get_value(lockdown, "ProductVersion", nil, &valPlist) == nil, let vp = valPlist {
            result.watchOSVersion = getRustPlistString(vp) ?? ""
            safeFreePlist(vp)
        }
        step("8: watch identity: \(result.watchProductType) watchOS \(result.watchOSVersion)")

        // build7 on hardware: reached the watch's lockdownd but SideStore's pairing
        // file is RemotePairing-format — it has no HostID/SystemBUID. Those are NOT
        // secrets from the phone's pairing; lockdownd_pair mints a fresh host
        // identity (new keys) and these are just the identifiers written into the
        // new record (libimobiledevice/pymobiledevice3 use random uppercase UUIDs).
        // Prefer the phone's if a lockdown-format file is loaded, else use a stable
        // per-install identity so the watch keeps trusting us across re-signs.
        let (hostID, systemBUID) = Self.watchHostIdentity(phonePairing: pairingDataDict)
        step("9: pairing with watch (HostID \(hostID.prefix(8))…) — WATCH TRUST PROMPT EXPECTED")
        var watchPairing: OpaquePointer? = nil
        // Call lockdownd_pair EXACTLY ONCE. The Rust pair() already loops internally
        // on PairingDialogResponsePending (sleeps 1s and retries until the user taps
        // Trust on the watch), so it blocks here and never returns code 30. build9
        // crashed (SIGSEGV in lockdownd_do_pair) because our own retry loop called
        // pair() a SECOND time on the same client whose state machine had already
        // advanced. One call, one wait. C-strings kept alive for its full duration.
        step("9: (this blocks until you tap Trust on the watch)")
        let pairErr: UnsafeMutablePointer<IdeviceFfiError>? =
            hostID.withCString { hostIDPtr in
                systemBUID.withCString { buidPtr in
                    "SideStore".withCString { hostNamePtr -> UnsafeMutablePointer<IdeviceFfiError>? in
                        lockdownd_pair(lockdown, hostIDPtr, buidPtr, hostNamePtr, &watchPairing)
                    }
                }
            }
        if let err = pairErr {
            let msg = getErrorMessage(from: err)
            let code = err.pointee.code
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_pair(watch) failed (code \(code)): \(msg)")
        }
        guard let watchPairing else {
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_pair(watch) returned no pairing record")
        }
        result.paired = true
        step("10: PAIRED with watch")

        // ── 5. session ──────────────────────────────────────────────────────
        if let err = lockdownd_start_session(lockdown, watchPairing) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            idevice_pairing_file_free(watchPairing)
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_start_session(watch) failed: \(msg)")
        }
        result.sessionStarted = true
        step("11: SESSION STARTED — watch lockdown fully reachable")

        // The FFI's lockdownd_start_session does not surface the `legacy` TLS
        // flag; watchOS 26 is modern TLS. Pass false to idevice_start_session.
        lockdownOwned = false
        return WatchLockdownSession(lockdown: lockdown, pairing: watchPairing, legacy: false, connectedHost: host)
    }

    /// Start a service on the watch's lockdownd, forward it, connect, and wrap
    /// in TLS if lockdownd says so. Caller owns the returned IdeviceHandle and
    /// must call `stopForwarding(remotePort)` afterwards.
    private func openWatchService(_ service: String, session: WatchLockdownSession, step: (String) -> Void) throws -> (device: OpaquePointer, remotePort: UInt16) {
        var remotePort: UInt16 = 0
        var ssl = false
        if let err = service.withCString({ lockdownd_start_service(session.lockdown, $0, &remotePort, &ssl) }) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "watch start_service(\(service)) failed: \(msg)")
        }
        step("W: \(service) on watch port \(remotePort) ssl=\(ssl)")
        let localPort = try forwardWatchPort(remotePort, label: service)
        let (dev, _) = try connectForwardedPort(localPort, label: service, step: step)
        if ssl {
            if let err = idevice_start_session(dev, session.pairing, session.legacy) {
                let msg = getErrorMessage(from: err)
                safeFreeError(err)
                idevice_free(dev)
                stopForwarding(remotePort, step: step)
                throw IdeviceGatewayError(.serviceError, reason: "TLS to watch \(service) failed: \(msg)")
            }
        }
        return (dev, remotePort)
    }

    // MARK: - Install: uninstall placeholder

    private func removeExistingWatchApp(bundleID: String, session: WatchLockdownSession, step: (String) -> Void) throws {
        let (dev, remotePort) = try openWatchService(Self.watchInstallProxyService, session: session, step: step)
        defer { stopForwarding(remotePort, step: step) }

        // installation_proxy_new CONSUMES `dev` (Box::from_raw) — never idevice_free it after this.
        var client: OpaquePointer? = nil
        if let err = installation_proxy_new(dev, &client) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "watch installation_proxy_new failed: \(msg)")
        }
        defer { if let client { installation_proxy_client_free(client) } }

        if let err = bundleID.withCString({ installation_proxy_uninstall(client, $0, nil) }) {
            // Missing bundle is expected on first install; stale coordinators surface via zip_conduit.
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            step("W: no removable watch app/placeholder for \(bundleID): \(msg)")
        } else {
            step("W: removed existing watch app/placeholder \(bundleID)")
        }
    }

    // MARK: - Install: streaming_zip_conduit

    private func streamWatchApp(at appURL: URL, session: WatchLockdownSession, step: (String) -> Void) throws {
        let (dev, remotePort) = try openWatchService(Self.watchZipConduitService, session: session, step: step)
        defer {
            idevice_free(dev)
            stopForwarding(remotePort, step: step)
        }

        let appName = appURL.lastPathComponent
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else {
            throw IdeviceGatewayError(.serviceError, reason: "Cannot enumerate \(appURL.path)")
        }
        var entries: [(URL, String)] = []
        var totalUncompressed: Int64 = 0
        let basePath = appURL.standardizedFileURL.path
        for case let url as URL in enumerator {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath + "/") else { continue }
            let rel = String(full.dropFirst(basePath.count + 1))
            entries.append((url, "Payload/\(appName)/\(rel)"))
            totalUncompressed += Int64(rv.fileSize ?? 0)
        }
        entries.sort { $0.1 < $1.1 }
        step("W: streaming \(entries.count) files, \(totalUncompressed) bytes")

        // InitTransfer header
        let initTransfer: [String: Any] = [
            "InstallOptionsDictionary": [
                "DisableDeltaTransfer": 1,
                "InstallDeltaTypeKey": "InstallDeltaTypeSparseIPAFiles",
                "IsUserInitiated": 1,
                "PackageType": "Customer",
                "PreferWifi": 1,
            ] as [String: Any],
            "InstallTransferredDirectory": 1,
            "MediaSubdir": "PublicStaging/\(appName).ipa",
            "UserInitiatedTransfer": 0,
        ]
        try sendPrefixedPlist(dev, initTransfer)

        // META-INF/com.apple.ZipMetadata.plist
        let metadata: [String: Any] = [
            "StandardDirectoryPerms": 16877,
            "StandardFilePerms": -32348,
            "RecordCount": entries.count + 2,
            "TotalUncompressedBytes": totalUncompressed,
            "Version": 2,
        ]
        let metadataBytes = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try sendRaw(dev, Self.zipLocalHeader(name: "META-INF/", size: 0, crc32: 0))
        try sendRaw(dev, Self.zipLocalHeader(name: "META-INF/com.apple.ZipMetadata.plist", size: UInt32(metadataBytes.count), crc32: Self.crc32(metadataBytes)))
        try sendRaw(dev, metadataBytes)

        var sent: Int64 = 0
        var lastPct = -1
        for (url, dest) in entries {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= Int(UInt32.max) else {
                throw IdeviceGatewayError(.serviceError, reason: "Watch app file too large for zip stream: \(dest)")
            }
            try sendRaw(dev, Self.zipLocalHeader(name: dest, size: UInt32(data.count), crc32: Self.crc32(data)))
            try sendRaw(dev, data)
            sent += Int64(data.count)
            let pct = totalUncompressed > 0 ? Int(sent * 100 / totalUncompressed) : 100
            if pct / 10 != lastPct / 10 { step("W: upload \(pct)%"); lastPct = pct }
        }

        // Bare central-directory signature ends the stream.
        try sendRaw(dev, Data([0x50, 0x4b, 0x01, 0x02]))
        step("W: upload complete, waiting for watchOS installer…")

        // Progress frames
        while true {
            let response = try readPrefixedPlist(dev)
            if let status = response["Status"] as? String, status == "DataComplete" {
                step("W: watchOS reports DataComplete")
                return
            }
            guard let prog = response["InstallProgressDict"] as? [String: Any] else {
                throw IdeviceGatewayError(.serviceError, reason: "Unexpected watch install response: \(response)")
            }
            if let error = prog["Error"] as? String {
                let desc = prog["ErrorDescription"] as? String ?? "No ErrorDescription returned by watchOS"
                throw IdeviceGatewayError(.serviceError, reason: "Watch installation failed: \(error): \(desc)")
            }
            let pct = (prog["PercentComplete"] as? NSNumber)?.intValue ?? 0
            let status = prog["Status"] as? String ?? "Unknown"
            step("W: installing on watch \(pct)% \(status)")
        }
    }

    // MARK: - Host identity for the watch pairing record

    private static let hostIDKey = "sidestore.watch.hostID"
    private static let systemBUIDKey = "sidestore.watch.systemBUID"

    static func watchHostIdentity(phonePairing: [String: any Sendable]?) -> (hostID: String, systemBUID: String) {
        if let d = phonePairing,
           let h = d["HostID"] as? String, !h.isEmpty,
           let b = d["SystemBUID"] as? String, !b.isEmpty {
            return (h, b)
        }
        let ud = UserDefaults.standard
        if let h = ud.string(forKey: hostIDKey), let b = ud.string(forKey: systemBUIDKey), !h.isEmpty, !b.isEmpty {
            return (h, b)
        }
        let h = UUID().uuidString.uppercased()
        let b = UUID().uuidString.uppercased()
        ud.set(h, forKey: hostIDKey)
        ud.set(b, forKey: systemBUIDKey)
        return (h, b)
    }

    // MARK: - Raw framing helpers

    private func sendRaw(_ dev: OpaquePointer, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            if let err = idevice_send_raw(dev, base, UInt(buf.count)) {
                let msg = getErrorMessage(from: err)
                safeFreeError(err)
                throw IdeviceGatewayError(.serviceError, reason: "send to watch failed: \(msg)")
            }
        }
    }

    private func readRaw(_ dev: OpaquePointer, _ len: Int) throws -> Data {
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        if let err = idevice_read_raw(dev, UInt(len), &ptr) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "read from watch failed: \(msg)")
        }
        guard let ptr else { return Data() }
        defer { idevice_data_free(ptr, UInt(len)) }
        return Data(bytes: ptr, count: len)
    }

    private func sendPrefixedPlist(_ dev: OpaquePointer, _ dict: [String: Any]) throws {
        let payload = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        var frame = Data(capacity: payload.count + 4)
        var be = UInt32(payload.count).bigEndian
        frame.append(Data(bytes: &be, count: 4))
        frame.append(payload)
        try sendRaw(dev, frame)
    }

    private func readPrefixedPlist(_ dev: OpaquePointer) throws -> [String: Any] {
        let lenData = try readRaw(dev, 4)
        let len = lenData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        guard len > 0, len < 16 * 1024 * 1024 else {
            throw IdeviceGatewayError(.serviceError, reason: "Watch sent implausible plist frame length \(len)")
        }
        let payload = try readRaw(dev, Int(len))
        let obj = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        guard let dict = obj as? [String: Any] else {
            throw IdeviceGatewayError(.serviceError, reason: "Expected dictionary plist from watch")
        }
        return dict
    }

    // MARK: - Zip (stored) local header, matching isideload byte-for-byte

    private static let zipExtra: [UInt8] = [
        0x55, 0x54, 0x0d, 0x00, 0x07, 0xf3, 0xa2, 0xec, 0x60, 0xf6, 0xa2, 0xec, 0x60, 0xf3,
        0xa2, 0xec, 0x60, 0x75, 0x78, 0x0b, 0x00, 0x01, 0x04, 0xf5, 0x01, 0x00, 0x00, 0x04,
        0x14, 0x00, 0x00, 0x00,
    ]

    private static func zipLocalHeader(name: String, size: UInt32, crc32: UInt32) -> Data {
        let nameBytes = Array(name.utf8)
        var h = Data(capacity: 30 + nameBytes.count + zipExtra.count)
        func u16(_ v: UInt16) { var le = v.littleEndian; h.append(Data(bytes: &le, count: 2)) }
        func u32(_ v: UInt32) { var le = v.littleEndian; h.append(Data(bytes: &le, count: 4)) }
        u32(0x04034b50)         // local file header signature
        u16(20)                 // version needed
        u16(0)                  // flags
        u16(0)                  // compression: stored
        u16(0xbdef)             // mod time
        u16(0x52ec)             // mod date
        u32(crc32)
        u32(size)               // compressed
        u32(size)               // uncompressed
        u16(UInt16(nameBytes.count))
        u16(UInt16(zipExtra.count))
        h.append(contentsOf: nameBytes)
        h.append(contentsOf: zipExtra)
        return h
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return ~crc
    }
}
