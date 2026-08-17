import AppKit
import Combine
import CryptoKit
import Foundation

struct ArkeyReleaseCatalog: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let releases: [ArkeyRelease]
}

struct ArkeyRelease: Codable, Identifiable, Equatable {
    let id: String
    let version: String
    let publishedAt: Date
    let dmgURL: URL
    let sha256: String
    let size: Int64
    let notes: [String]
    let firmware: [String]
}

enum ArkeyUpdateState: Equatable {
    case idle
    case checking
    case downloading(String)
    case verifying(String)
    case opening(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "已准备好"
        case .checking: "正在检查更新…"
        case .downloading(let version): "正在下载 ARkey \(version)…"
        case .verifying(let version): "正在验证 ARkey \(version)…"
        case .opening(let version): "已验证，正在打开 ARkey \(version) 的安装盘…"
        case .failed(let message): message
        }
    }
}

enum ArkeyUpdateError: LocalizedError {
    case invalidManifest
    case signatureInvalid
    case noCompatibleRelease
    case manifestUnavailable(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新清单格式无效。"
        case .signatureInvalid: "更新清单签名无效，已拒绝下载。"
        case .noCompatibleRelease: "没有可用的 ARkey 发布版本。"
        case .manifestUnavailable(let description): "无法连接更新服务器：\(description)"
        case .sizeMismatch(let expected, let actual): "下载文件大小不匹配（期望 \(expected) 字节，实际 \(actual) 字节）。"
        case .hashMismatch: "下载文件校验失败，已拒绝打开。"
        case .downloadFailed(let description): "下载更新失败：\(description)"
        }
    }
}

@MainActor
final class ArkeyUpdateService: ObservableObject {
    static let manifestURL = URL(string: "https://updates.arkey.fun/v1/releases.json")!
    // `arkey.fun` is deliberately a separate HTTPS origin. It is used only
    // when a network has cached or filtered the updates subdomain. Both paths
    // serve the identical signed catalog, and every downloaded DMG still has
    // to match the catalog's SHA-256 before Finder can open it.
    static let fallbackManifestURL = URL(string: "https://arkey.fun/updates/v1/releases.json")!
    static let fallbackArtifactBaseURL = URL(string: "https://arkey.fun/updates")!
    static let keyID = "arkey-update-2026-01"
    // This is a public Ed25519 verification key. The matching private key is
    // deliberately outside the repository and is used only by the local
    // release publisher.
    static let publicKeyBase64 = "RZq/9YnRpX1s9HI/g9dWyw1T3h/2J1sP97eulHM0r70="

    @Published private(set) var catalog: ArkeyReleaseCatalog?
    @Published private(set) var state: ArkeyUpdateState = .idle
    @Published private(set) var lastChecked: Date?

    private let manifestURLs: [URL]
    private let session: URLSession
    private let directSession: URLSession
    private let publicKey: Curve25519.Signing.PublicKey
    private var periodicTask: Task<Void, Never>?

    init(
        manifestURL: URL = ArkeyUpdateService.manifestURL,
        fallbackManifestURL: URL? = ArkeyUpdateService.fallbackManifestURL,
        publicKeyBase64: String = ArkeyUpdateService.publicKeyBase64,
        session: URLSession = .shared
    ) {
        self.manifestURLs = [manifestURL] + (fallbackManifestURL.map { [$0] } ?? [])
        self.session = session
        let directConfiguration = URLSessionConfiguration.ephemeral
        // Some macOS installations keep a stale PAC/proxy endpoint. Preserve
        // the user's normal path first, then retry this signed-update request
        // directly; TLS and the release signature remain mandatory either way.
        directConfiguration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0]
        self.directSession = URLSession(configuration: directConfiguration)
        self.publicKey = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKeyBase64)!)
    }

    deinit { periodicTask?.cancel() }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releases: [ArkeyRelease] {
        (catalog?.releases ?? []).sorted { Self.compareVersions($0.version, $1.version) == .orderedDescending }
    }

    var newestRelease: ArkeyRelease? { releases.first }

    var hasAvailableUpdate: Bool {
        guard let newestRelease else { return false }
        return Self.compareVersions(newestRelease.version, Self.currentVersion) == .orderedDescending
    }

    func start() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            guard let self else { return }
            await self.checkForUpdates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 21_600_000_000_000)
                guard !Task.isCancelled else { return }
                await self.checkForUpdates()
            }
        }
    }

    func checkForUpdates() async {
        guard !isBusy else { return }
        state = .checking
        var failures: [String] = []
        for transport in transports {
            for endpoint in manifestURLs {
                do {
                    let decoded = try await fetchCatalog(at: endpoint, using: transport.session)
                    catalog = decoded
                    lastChecked = Date()
                    state = .idle
                    ArkeyDiagnostics.shared.record(category: .update, name: "update.catalog.checked", details: ["releaseCount": "\(decoded.releases.count)", "newest": releases.first?.version ?? "none", "endpointHost": endpoint.host ?? "unknown", "transport": transport.name])
                    return
                } catch {
                    let detail = Self.networkFailureDetail(error)
                    failures.append("\(transport.name)/\(endpoint.host ?? "server"): \(detail.message)")
                    var diagnostics = detail.diagnosticDetails(endpoint: endpoint)
                    diagnostics["transport"] = transport.name
                    ArkeyDiagnostics.shared.record(category: .network, severity: .warning, name: "update.catalog.endpoint.failed", details: diagnostics)
                }
            }
        }
        do {
            throw ArkeyUpdateError.manifestUnavailable(failures.joined(separator: "；"))
        } catch {
            lastChecked = Date()
            state = .failed(error.localizedDescription)
            ArkeyDiagnostics.shared.record(category: .update, severity: .warning, name: "update.catalog.failed", details: ["attemptCount": "\(manifestURLs.count)", "errorKind": "manifest-unavailable"])
        }
    }

    func downloadAndOpen(_ release: ArkeyRelease) async {
        guard !isBusy else { return }
        do {
            let sources = Self.artifactURLs(for: release)
            var failures: [String] = []
            for transport in transports {
                for source in sources {
                    do {
                        state = .downloading(release.version)
                        ArkeyDiagnostics.shared.record(category: .update, name: "update.download.started", details: ["version": release.version, "release": release.id, "endpointHost": source.host ?? "unknown", "transport": transport.name])
                        var request = URLRequest(url: source)
                        request.timeoutInterval = 180
                        let (temporaryURL, response) = try await transport.session.download(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ArkeyUpdateError.downloadFailed("服务器返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)") }
                        state = .verifying(release.version)
                        let destination = try cacheDownloadedDMG(temporaryURL, release: release)
                        try Self.validateDMG(at: destination, release: release)
                        state = .opening(release.version)
                        guard NSWorkspace.shared.open(destination) else { throw ArkeyUpdateError.downloadFailed("无法在 Finder 中打开已验证的 DMG") }
                        ArkeyDiagnostics.shared.record(category: .update, name: "update.dmg.opened", details: ["version": release.version, "sha256": String(release.sha256.prefix(12)), "endpointHost": source.host ?? "unknown", "transport": transport.name])
                        state = .idle
                        return
                    } catch {
                        let detail = Self.networkFailureDetail(error)
                        failures.append("\(transport.name)/\(source.host ?? "server"): \(detail.message)")
                        var diagnostics = detail.diagnosticDetails(endpoint: source)
                        diagnostics["transport"] = transport.name
                        ArkeyDiagnostics.shared.record(category: .network, severity: .warning, name: "update.download.endpoint.failed", details: diagnostics)
                    }
                }
            }
            throw ArkeyUpdateError.downloadFailed(failures.joined(separator: "；"))
        } catch {
            state = .failed(error.localizedDescription)
            ArkeyDiagnostics.shared.record(category: .update, severity: .error, name: "update.download.failed", details: ["version": release.version, "error": error.localizedDescription])
        }
    }

    private var transports: [UpdateTransport] {
        [UpdateTransport(name: "system-proxy", session: session), UpdateTransport(name: "direct", session: directSession)]
    }

    private func fetchCatalog(at endpoint: URL, using session: URLSession) async throws -> ArkeyReleaseCatalog {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ArkeyUpdateError.invalidManifest }
        let decoded = try Self.decodeSignedCatalog(data, publicKey: publicKey)
        guard decoded.schemaVersion == 1, !decoded.releases.isEmpty else { throw ArkeyUpdateError.noCompatibleRelease }
        return decoded
    }

    func retry() { Task { await checkForUpdates() } }

    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .opening: true
        default: false
        }
    }

    private func cacheDownloadedDMG(_ temporaryURL: URL, release: ArkeyRelease) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARkey/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeID = release.id.replacingOccurrences(of: "/", with: "-")
        let destination = root.appendingPathComponent("ARkey-\(safeID).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static func decodeSignedCatalog(_ data: Data, publicKey: Curve25519.Signing.PublicKey) throws -> ArkeyReleaseCatalog {
        let envelope = try JSONDecoder.diagnostic.decode(SignedReleaseCatalog.self, from: data)
        guard envelope.algorithm == "ed25519", envelope.keyID == keyID,
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              publicKey.isValidSignature(signature, for: payload) else { throw ArkeyUpdateError.signatureInvalid }
        return try JSONDecoder.diagnostic.decode(ArkeyReleaseCatalog.self, from: payload)
    }

    static func validateDMG(at url: URL, release: ArkeyRelease) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == release.size else { throw ArkeyUpdateError.sizeMismatch(expected: release.size, actual: actualSize) }
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else { throw ArkeyUpdateError.hashMismatch }
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return lhs == rhs ? .orderedSame : lhs.localizedStandardCompare(rhs)
    }

    static func artifactURLs(for release: ArkeyRelease) -> [URL] {
        var values = [release.dmgURL]
        let path = release.dmgURL.path.hasPrefix("/") ? String(release.dmgURL.path.dropFirst()) : release.dmgURL.path
        guard release.dmgURL.host == manifestURL.host, !path.isEmpty else { return values }
        let fallback = fallbackArtifactBaseURL.appendingPathComponent(path)
        values.append(fallback)
        return values
    }

    private static func networkFailureDetail(_ error: Error) -> NetworkFailureDetail {
        let nsError = error as NSError
        let urlCode = (error as? URLError)?.code.rawValue
        let code = urlCode ?? nsError.code
        let domain = (error as? URLError) == nil ? nsError.domain : "NSURLErrorDomain"
        return NetworkFailureDetail(domain: domain, code: code)
    }
}

private struct UpdateTransport {
    let name: String
    let session: URLSession
}

private struct NetworkFailureDetail {
    let domain: String
    let code: Int

    var message: String { "\(domain) (\(code))" }

    func diagnosticDetails(endpoint: URL) -> [String: String] {
        ["endpointHost": endpoint.host ?? "unknown", "endpointPath": endpoint.path, "errorDomain": domain, "errorCode": "\(code)"]
    }
}

private struct SignedReleaseCatalog: Codable {
    let algorithm: String
    let keyID: String
    let payload: String
    let signature: String
}
