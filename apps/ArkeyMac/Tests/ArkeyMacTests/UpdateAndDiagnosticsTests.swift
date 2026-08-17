import CryptoKit
import Foundation
import Testing
@testable import ArkeyMac

@Suite("ARkey updates and diagnostics")
struct UpdateAndDiagnosticsTests {
    @Test("signed release catalog accepts the matching Ed25519 signature")
    @MainActor
    func signedCatalog() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let release = ArkeyRelease(
            id: "3.0.0",
            version: "3.0.0",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dmgURL: URL(string: "https://updates.example.test/releases/3.0.0/ARkey.dmg")!,
            sha256: String(repeating: "a", count: 64),
            size: 128,
            notes: ["完整资源包"],
            firmware: ["v1-max-v0.1.9"]
        )
        let payload = try JSONEncoder.diagnostic.encode(ArkeyReleaseCatalog(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_700_000_000), releases: [release]))
        let envelope: [String: String] = [
            "algorithm": "ed25519",
            "keyID": ArkeyUpdateService.keyID,
            "payload": payload.base64EncodedString(),
            "signature": try privateKey.signature(for: payload).base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let result = try ArkeyUpdateService.decodeSignedCatalog(data, publicKey: privateKey.publicKey)
        #expect(result.releases == [release])
    }

    @Test("signed release catalog accepts fractional-second publication times")
    @MainActor
    func fractionalSecondCatalog() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"schemaVersion":1,"generatedAt":"2026-08-16T06:06:19.798Z","releases":[{"id":"3.0.2","version":"3.0.2","publishedAt":"2026-08-16T06:06:19.797Z","dmgURL":"https://updates.arkey.fun/releases/3.0.2/ARkey-3.0.2.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1,"notes":[],"firmware":[]}]}"#.utf8)
        let envelope: [String: String] = [
            "algorithm": "ed25519",
            "keyID": ArkeyUpdateService.keyID,
            "payload": payload.base64EncodedString(),
            "signature": try privateKey.signature(for: payload).base64EncodedString(),
        ]
        let result = try ArkeyUpdateService.decodeSignedCatalog(JSONSerialization.data(withJSONObject: envelope), publicKey: privateKey.publicKey)
        #expect(result.releases.first?.version == "3.0.2")
    }

    @Test("tampered catalog signature is rejected")
    @MainActor
    func rejectsTamperedCatalog() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("{\"schemaVersion\":1,\"generatedAt\":\"2025-01-01T00:00:00Z\",\"releases\":[]}".utf8)
        let envelope: [String: String] = [
            "algorithm": "ed25519",
            "keyID": ArkeyUpdateService.keyID,
            "payload": payload.base64EncodedString(),
            "signature": Data(repeating: 0, count: 64).base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: ArkeyUpdateError.self) {
            try ArkeyUpdateService.decodeSignedCatalog(data, publicKey: privateKey.publicKey)
        }
    }

    @Test("release comparison supports normal updates and downgrade ordering")
    @MainActor
    func versionOrdering() {
        #expect(ArkeyUpdateService.compareVersions("3.0.0", "2.9.9") == .orderedDescending)
        #expect(ArkeyUpdateService.compareVersions("2.2.2", "2.2.2") == .orderedSame)
        #expect(ArkeyUpdateService.compareVersions("2.1.9", "2.2.0") == .orderedAscending)
    }

    @Test("signed updates can use only the controlled HTTPS fallback origin")
    @MainActor
    func artifactFallback() {
        let primary = URL(string: "https://updates.arkey.fun/releases/3.0.1/ARkey-3.0.1.dmg")!
        let release = ArkeyRelease(id: "3.0.1", version: "3.0.1", publishedAt: .now, dmgURL: primary, sha256: String(repeating: "a", count: 64), size: 1, notes: [], firmware: [])
        #expect(ArkeyUpdateService.artifactURLs(for: release).map(\.absoluteString) == [
            "https://updates.arkey.fun/releases/3.0.1/ARkey-3.0.1.dmg",
            "https://arkey.fun/updates/releases/3.0.1/ARkey-3.0.1.dmg",
        ])
    }

    @Test("DMG validator rejects a hash mismatch")
    @MainActor
    func rejectsCorruptDownload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arkey-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ARkey.dmg")
        let data = Data("not a dmg".utf8)
        try data.write(to: url)
        let release = ArkeyRelease(id: "x", version: "1.0.0", publishedAt: Date(), dmgURL: url, sha256: String(repeating: "0", count: 64), size: Int64(data.count), notes: [], firmware: [])
        #expect(throws: ArkeyUpdateError.self) { try ArkeyUpdateService.validateDMG(at: url, release: release) }
    }

    @Test("diagnostics redact serial, workspace and raw HID content")
    func diagnosticRedaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arkey-diagnostic-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = ArkeyDiagnostics(storageURL: directory, uploadEndpoint: nil)
        let session = diagnostics.beginSession(reason: "test")
        diagnostics.record(
            category: .hid,
            name: "hid.report",
            details: ["serialNumber": "hidden", "workspacePath": "hidden", "rawPayload": "hidden", "reportID": "07"],
            sessionID: session
        )
        let event = try #require(diagnostics.events(for: session).first(where: { $0.name == "hid.report" }))
        #expect(event.details["serialNumber"] == nil)
        #expect(event.details["workspacePath"] == nil)
        #expect(event.details["rawPayload"] == nil)
        #expect(event.details["reportID"] == "07")
    }
}
