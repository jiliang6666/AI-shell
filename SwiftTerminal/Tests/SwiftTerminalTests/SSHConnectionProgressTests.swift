import AppKit
import Testing
@testable import SwiftTerminal

struct SSHConnectionProgressTests {
    @Test(arguments: ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.10"])
    func privateAddressesFailSooner(address: String) {
        #expect(SSHConnectionPolicy.connectTimeout(address: address) == 8)
    }

    @Test(arguments: ["203.0.113.9", "nas.local", "172.32.0.1", "192.168.1.256", "10..1.2", "::1"])
    func otherAddressesKeepRemoteTimeout(address: String) {
        #expect(SSHConnectionPolicy.connectTimeout(address: address) == 15)
    }

    @Test func bannerAndFingerprintPromptDoNotProveLogin() {
        let generation = UUID()
        var progress = SSHConnectionProgress(generation: generation, expectsReadyMarker: true)
        progress.receive("Welcome to NAS\nAre you sure you want to continue connecting (yes/no")
        #expect(progress.state == .needsInput)
        progress.receiveTitle("__SWIFTTERMINAL_READY=\(UUID().uuidString.lowercased())")
        #expect(progress.state == .needsInput)
        progress.receiveTitle("__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())")
        #expect(progress.state == .connected)
        progress.finish()
        #expect(progress.state == .disconnected)
    }

    @Test func chunkedNetworkFailureIsReportedAtProcessExit() {
        var progress = SSHConnectionProgress(generation: UUID(), expectsReadyMarker: true)
        progress.receive("ssh: connect to host: Operation tim")
        progress.receive("ed out\r\n")
        #expect(progress.state == .connecting)
        progress.finish()
        #expect(progress.state == .failed(.network))
        #expect(SSHConnectionFailure.network.message(address: "192.168.1.10").contains("远程地址"))
    }

    @Test(arguments: [
        ("Permission denied (publickey,password).", SSHConnectionFailure.authentication),
        ("Host key verification failed.", SSHConnectionFailure.hostKey),
        ("Connection refused", SSHConnectionFailure.network)
    ])
    func startupFailureKeepsItsReason(output: String, failure: SSHConnectionFailure) {
        var progress = SSHConnectionProgress(generation: UUID(), expectsReadyMarker: true)
        progress.receive(output)
        progress.finish()
        #expect(progress.state == .failed(failure))
    }

    @Test func cancellationCannotBeOverwrittenByLateOutputOrExit() {
        let generation = UUID()
        var progress = SSHConnectionProgress(generation: generation, expectsReadyMarker: true)
        progress.cancel()
        progress.receive("Permission denied")
        progress.receiveTitle("__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())")
        progress.finish()
        #expect(progress.state == .cancelled)
    }

    @Test func commandOutputAfterLoginCannotBecomeConnectionFailure() {
        let generation = UUID()
        var progress = SSHConnectionProgress(generation: generation, expectsReadyMarker: true)
        progress.receiveTitle("__SWIFTTERMINAL_READY=\(generation.uuidString.lowercased())")
        progress.receive("cat: Permission denied")
        #expect(progress.state == .connected)
        progress.finish()
        #expect(progress.state == .disconnected)
    }

    @Test func unsupportedShellDoesNotClaimVerifiedConnection() {
        var progress = SSHConnectionProgress(generation: UUID(), expectsReadyMarker: false)
        progress.receive("shell prompt >")
        #expect(progress.state == .terminalOpen)
    }

    @Test @MainActor func cancellingBeforeLayoutPreventsDelayedLaunch() async {
        let pane = TerminalPaneView(frame: .zero)
        var states: [SSHConnectionState] = []
        let host = SSHHost(name: "isolated", address: "192.0.2.1", username: "fixture", savePassword: false)
        pane.prepareSSH(host, environment: [], onState: { states.append($0) })
        pane.cancelSSHConnection()
        await Task.yield()
        #expect(states == [.connecting, .cancelled])
        #expect(pane.process?.running != true)
        pane.stopForRemoval()
    }
}
