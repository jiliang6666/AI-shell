import Foundation

enum SSHConnectionState: Equatable, Sendable {
    case connecting, needsInput, terminalOpen, connected, disconnected, cancelled
    case failed(SSHConnectionFailure)

    var label: String {
        switch self {
        case .connecting: "连接中"
        case .needsInput: "等待终端确认"
        case .terminalOpen: "终端已打开"
        case .connected: "已连接"
        case .disconnected: "已断开"
        case .cancelled: "已取消"
        case .failed: "连接失败"
        }
    }

    var canCancel: Bool { self == .connecting || self == .needsInput }
    var canRetry: Bool {
        switch self {
        case .failed, .disconnected, .cancelled: true
        default: false
        }
    }
}

enum SSHConnectionFailure: Equatable, Sendable {
    case network, authentication, hostKey, other

    func message(address: String) -> String {
        switch self {
        case .network:
            SSHConnectionPolicy.isPrivateIPv4(address)
                ? "内网地址暂时不可达。请连接同一网络，或使用已配置的远程地址。"
                : "暂时无法连接主机，请检查网络和主机地址。"
        case .authentication: "认证未完成，请检查账号和认证资料。"
        case .hostKey: "主机身份校验未通过，请核对终端中的提示。"
        case .other: "连接未建立，请查看终端提示后重试。"
        }
    }
}

enum SSHConnectionPolicy {
    static func isPrivateIPv4(_ address: String) -> Bool {
        let components = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    static func connectTimeout(address: String) -> Int { isPrivateIPv4(address) ? 8 : 15 }
}

/// Reads only bounded startup output. A shell readiness marker is the positive
/// connection signal; banners and authentication prompts cannot prove login.
struct SSHConnectionProgress {
    private(set) var state = SSHConnectionState.connecting
    private var startupOutput = ""
    private var failure: SSHConnectionFailure?
    let generation: UUID
    let expectsReadyMarker: Bool

    init(generation: UUID, expectsReadyMarker: Bool) {
        self.generation = generation
        self.expectsReadyMarker = expectsReadyMarker
    }

    mutating func receive(_ text: String) {
        guard !state.canRetry, state != .connected else { return }
        startupOutput = String((startupOutput + text).suffix(4096))
        let output = startupOutput.lowercased()
        if output.contains("connection timed out") || output.contains("operation timed out")
            || output.contains("no route to host") || output.contains("network is unreachable")
            || output.contains("connection refused") || output.contains("could not resolve hostname") {
            failure = .network
        } else if output.contains("permission denied") || output.contains("authentication failed") {
            failure = .authentication
        } else if output.contains("host key verification failed") || output.contains("remote host identification has changed") {
            failure = .hostKey
        }
        if output.contains("yes/no") || output.contains("password:") || output.contains("passphrase")
            || output.contains("verification code:") {
            state = .needsInput
        } else if !expectsReadyMarker, failure == nil, !text.isEmpty {
            state = .terminalOpen
        }
    }

    mutating func receiveTitle(_ title: String) {
        guard !state.canRetry else { return }
        if title == "__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())" {
            state = .connected
            startupOutput = ""
            failure = nil
        }
    }

    mutating func finish() {
        guard !state.canRetry else { return }
        state = (state == .connected || state == .terminalOpen) ? .disconnected : .failed(failure ?? .other)
        startupOutput = ""
    }

    mutating func cancel() {
        guard state.canCancel else { return }
        state = .cancelled
        startupOutput = ""
    }
}
