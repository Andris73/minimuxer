//
//  IdeviceGateway+WatchCompanion.swift
//  DeviceGateway
//
//  Spike + support for installing embedded Watch apps via the companion proxy
//  (isideload PR #12 flow, on-device). See docs/issue-229-fix.md in SideStore.
//
//  Flow: companion_proxy (RSD service on the phone) -> get_device_registry
//        -> start_forwarding_service_port(62078) -> TCP connect to forwarded
//        port -> lockdownd_new -> lockdownd_pair (trust prompt on watch)
//        -> lockdownd_start_session. Later stages reuse the same forwarding
//        for installation_proxy / streamed install.
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

extension IdeviceGateway {

    private static let watchLockdownPort: UInt16 = 62078

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

        // ── 1. companion_proxy over RSD ─────────────────────────────────────
        step("1: connecting companion_proxy over RSD…")
        let udids: [String] = try performWithService(
            connect: { adapter, handshake, client in
                companion_proxy_connect_rsd(adapter, handshake, client)
            },
            cleanup: { client in
                if let client { companion_proxy_client_free(client) }
            },
            serviceName: "companion_proxy(registry)"
        ) { client in
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
        let localPort: UInt16 = try performWithService(
            connect: { adapter, handshake, client in
                companion_proxy_connect_rsd(adapter, handshake, client)
            },
            cleanup: { client in
                if let client { companion_proxy_client_free(client) }
            },
            serviceName: "companion_proxy(forward)"
        ) { client in
            var port: UInt16 = 0
            if let err = companion_proxy_start_forwarding_service_port(client, Self.watchLockdownPort, &port) {
                let msg = self.getErrorMessage(from: err)
                self.safeFreeError(err)
                throw IdeviceGatewayError(.serviceError, reason: "start_forwarding(62078) failed: \(msg)")
            }
            return port
        }
        result.forwardedPort = localPort
        step("4: forwarded to local port \(localPort)")

        // ── 3. TCP connect to the forwarded port ────────────────────────────
        // Unknown which address the phone binds the forwarded port on when we
        // are ON the phone. Try loopback first, then the RSD tunnel endpoint.
        var candidates: [String] = ["127.0.0.1"]
        if let ep = deviceEndpointIp, !ep.isEmpty, ep != "127.0.0.1" { candidates.append(ep) }
        var idevice: OpaquePointer? = nil
        var lastErrMsg = "no candidates attempted"
        for host in candidates {
            for attempt in 1...5 {
                step("5: TCP connect \(host):\(localPort) (attempt \(attempt))…")
                var dev: OpaquePointer? = nil
                var addr = sockaddr_in()
                addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = localPort.bigEndian
                addr.sin_addr.s_addr = inet_addr(host)
                let err = withUnsafePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                        idevice_new_tcp_socket(sptr, socklen_t(MemoryLayout<sockaddr_in>.size), "watch-lockdown", &dev)
                    }
                }
                if err == nil, dev != nil {
                    idevice = dev
                    result.connectedVia = host
                    break
                }
                if let err {
                    lastErrMsg = getErrorMessage(from: err)
                    safeFreeError(err)
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
            if idevice != nil { break }
        }
        guard let watchDevice = idevice else {
            throw IdeviceGatewayError(.serviceError, reason: "TCP connect to forwarded watch lockdown failed on \(candidates.joined(separator: "/")): \(lastErrMsg)")
        }
        step("6: TCP connected via \(result.connectedVia)")

        // ── 4. lockdownd handshake + pair ───────────────────────────────────
        var lockdown: OpaquePointer? = nil
        if let err = lockdownd_new(watchDevice, &lockdown) {
            let msg = getErrorMessage(from: err)
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_new(watch) failed: \(msg)")
        }
        defer { if let lockdown { lockdownd_client_free(lockdown) } }
        step("7: watch lockdownd client created")

        // Identity probe (no session needed for basic values)
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

        // Pair using the PHONE's pairing-record identity (isideload flow).
        guard let dict = pairingDataDict,
              let hostID = dict["HostID"] as? String,
              let systemBUID = dict["SystemBUID"] as? String else {
            throw IdeviceGatewayError(.invalidPairingFile, reason: "Phone pairing record missing HostID/SystemBUID")
        }
        step("9: pairing with watch (HostID \(hostID.prefix(8))…) — WATCH TRUST PROMPT EXPECTED")
        var watchPairing: OpaquePointer? = nil
        var pairErr = lockdownd_pair(lockdown, hostID, systemBUID, "SideStore", &watchPairing)
        // PairingDialogResponsePending: keep polling while the user taps Trust.
        var waited = 0
        while let err = pairErr, err.pointee.code == 30, waited < 60 {
            safeFreeError(err)
            step("9: waiting for Trust on the watch… (\(waited)s)")
            Thread.sleep(forTimeInterval: 3.0)
            waited += 3
            pairErr = lockdownd_pair(lockdown, hostID, systemBUID, "SideStore", &watchPairing)
        }
        if let err = pairErr {
            let msg = getErrorMessage(from: err)
            let code = err.pointee.code
            safeFreeError(err)
            throw IdeviceGatewayError(.serviceError, reason: "lockdownd_pair(watch) failed (code \(code)): \(msg)")
        }
        result.paired = true
        step("10: PAIRED with watch")

        // Serialize the watch pairing record for later install stages.
        if let watchPairing {
            var data: UnsafeMutablePointer<UInt8>? = nil
            var size: UInt = 0
            if idevice_pairing_file_serialize(watchPairing, &data, &size) == nil, let data {
                result.pairingRecord = Data(bytes: data, count: Int(size))
                idevice_data_free(data, size)
            }
            // Start a session to prove the record is usable end-to-end.
            if let err = lockdownd_start_session(lockdown, watchPairing) {
                let msg = getErrorMessage(from: err)
                safeFreeError(err)
                step("11: start_session failed: \(msg) (record still saved)")
            } else {
                result.sessionStarted = true
                step("11: SESSION STARTED — watch lockdown fully reachable")
            }
            idevice_pairing_file_free(watchPairing)
        }

        idevice_free(watchDevice)
        step("12: spike complete")
        return result
    }
}
