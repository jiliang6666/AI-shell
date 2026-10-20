import AppKit
import Network

@MainActor
enum LocalNetworkAccess {
    private static var requestedAtLaunch = false
    private static var browser: NWBrowser?
    private static var expiry: Task<Void, Never>?

    // Only deduplicate windows; macOS owns the remembered authorization choice.
    static func requestAtLaunch() async {
        guard #available(macOS 15, *), !requestedAtLaunch else { return }
        requestedAtLaunch = true
        await request()
    }

    static func request() async {
        guard #available(macOS 15, *), browser == nil else { return }
        // Bonjour is already used to resolve SMB server aliases. Browsing this
        // declared service gives macOS a real operation to authorize, including
        // on IPv4-only networks. No credentials or file contents are sent.
        let probe = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        browser = probe
        probe.start(queue: DispatchQueue(label: "local.swiftterminal.network-permission"))
        // Keep the request alive while the person responds to the system prompt,
        // then release it. Browser readiness is not treated as authorization.
        expiry = Task {
            do { try await Task.sleep(for: .seconds(120)) }
            catch { return }
            probe.cancel()
            browser = nil
            expiry = nil
        }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }
}
