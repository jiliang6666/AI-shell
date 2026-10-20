import Combine
import Foundation
import Sparkle

enum UpdateReleasePolicy {
    static func publicGitHubFeedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value) else { return nil }
        let pathParts = components.percentEncodedPath.split(separator: "/")
        guard
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "github.com",
            components.port == nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.range(
                of: #"^/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/releases/latest/download/appcast\.xml$"#,
                options: .regularExpression
            ) != nil,
            pathParts.count == 6,
            pathParts[1] != ".",
            pathParts[1] != "..",
            let url = components.url else {
            return nil
        }
        return url
    }

    static func newestVersionIndex(_ versions: [String], newerThan revision: Int) -> Int? {
        versions.enumerated()
            .compactMap { index, version -> (index: Int, revision: Int)? in
                guard let parsed = Int(version), parsed > revision else { return nil }
                return (index, parsed)
            }
            .max { $0.revision < $1.revision }?
            .index
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    @Published private(set) var status: String
    @Published private(set) var isConfigured: Bool

    private let feedURL: URL?
    private let currentRevision: Int
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var checkInProgress = false
    private var hasStarted = false

    var automaticallyChecksForUpdates: Bool {
        get { isConfigured && updaterController.updater.automaticallyChecksForUpdates }
        set {
            guard isConfigured else { return }
            startIfNeeded()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private override convenience init() {
        self.init(info: Bundle.main.infoDictionary ?? [:])
    }

    init(info: [String: Any], startingUpdater: Bool = true) {
        let parsedFeed = UpdateReleasePolicy.publicGitHubFeedURL(info["SUFeedURL"] as? String ?? "")
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        let revision = Int(info["ZhanqiaoUpdateRevision"] as? String ?? "") ?? 0
        let validPublicKey = Data(base64Encoded: publicKey)?.count == 32
        let configured = parsedFeed != nil && validPublicKey && revision > 0

        feedURL = parsedFeed
        currentRevision = revision
        isConfigured = configured
        status = configured ? "软件更新已就绪" : "待配置公开仓库与签名公钥"
        super.init()

        if configured && startingUpdater { startIfNeeded() }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL?.absoluteString
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let versions = appcast.items.map(\.versionString)
        guard let index = UpdateReleasePolicy.newestVersionIndex(versions, newerThan: currentRevision) else {
            return SUAppcastItem.empty()
        }
        return appcast.items[index]
    }

    func checkForUpdates() {
        guard isConfigured else {
            status = "更新源或签名公钥尚未配置"
            return
        }
        startIfNeeded()
        guard updaterController.updater.canCheckForUpdates else {
            status = "更新检查正在进行中"
            return
        }
        checkInProgress = true
        status = "正在检查更新…"
        updaterController.checkForUpdates(nil)
    }

    private func startIfNeeded() {
        guard !hasStarted else { return }
        updaterController.startUpdater()
        hasStarted = true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        checkInProgress = false
        status = "发现更新：\(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        checkInProgress = false
        status = "当前已是最新版本"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        finishUpdate(with: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finishUpdate(with: error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            finishUpdate(with: error)
        } else if checkInProgress {
            checkInProgress = false
            status = "更新检查已结束"
        }
    }

    private func finishUpdate(with error: Error) {
        checkInProgress = false
        let value = error as NSError
        if value.domain == SUSparkleErrorDomain,
           value.code == Int(SUError.noUpdateError.rawValue) {
            status = "当前已是最新版本"
            return
        }
        if value.domain == SUSparkleErrorDomain,
           value.code == Int(SUError.installationCanceledError.rawValue) {
            status = "已取消更新"
            return
        }
        if value.domain == NSURLErrorDomain, value.code == URLError.cancelled.rawValue {
            status = "已取消更新"
            return
        }
        status = "更新失败：\(error.localizedDescription)"
    }
}
