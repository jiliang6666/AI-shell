import Foundation
import Testing
@testable import SwiftTerminal

@Test("SFTP listing includes hidden files so the visibility toggle can show them", .enabled(if: ProcessInfo.processInfo.environment["AI_RUN_SSH_TESTS"] == "1"))
func sftpListingIncludesHiddenFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SFTPHidden-\(UUID().uuidString)", isDirectory: true)
    let etc = root.appendingPathComponent("etc")
    let home = root.appendingPathComponent("home")
    let listing = home.appendingPathComponent("listing")
    try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: listing, withIntermediateDirectories: true)
    try "visible".write(to: listing.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(to: listing.appendingPathComponent(".hidden-file"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: listing.appendingPathComponent(".hidden-dir"), withIntermediateDirectories: true)
    let keygenClient = Process()
    keygenClient.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygenClient.arguments = ["-t", "ed25519", "-N", "", "-q", "-f", home.appendingPathComponent("client_ed25519").path]
    try keygenClient.run(); keygenClient.waitUntilExit()
    #expect(keygenClient.terminationStatus == 0)
    try FileManager.default.copyItem(at: home.appendingPathComponent("client_ed25519.pub"), to: home.appendingPathComponent("authorized_keys"))

    let port = Int.random(in: 21_000...60_000)
    let config = """
    Port \(port)
    ListenAddress 127.0.0.1
    HostKey \(etc.appendingPathComponent("host_ed25519").path)
    PidFile \(etc.appendingPathComponent("sshd.pid").path)
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile \(home.appendingPathComponent("authorized_keys").path)
    UsePAM no
    StrictModes no
    Subsystem sftp internal-sftp
    LogLevel ERROR
    """
    try Data(config.utf8).write(to: etc.appendingPathComponent("sshd_config"))
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-t", "ed25519", "-N", "", "-q", "-f", etc.appendingPathComponent("host_ed25519").path]
    try keygen.run(); keygen.waitUntilExit()
    #expect(keygen.terminationStatus == 0)

    let sshd = Process()
    sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    sshd.arguments = ["-D", "-f", etc.appendingPathComponent("sshd_config").path, "-E", etc.appendingPathComponent("sshd.log").path]
    try sshd.run()
    try await Task.sleep(for: .seconds(1))
    let knownHostsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/known_hosts")
    let knownHostsOriginal = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
    let keyscan = Process()
    keyscan.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
    keyscan.arguments = ["-p", String(port), "127.0.0.1"]
    let keyscanPipe = Pipe()
    keyscan.standardOutput = keyscanPipe
    keyscan.standardError = FileHandle.nullDevice
    try keyscan.run(); keyscan.waitUntilExit()
    let keyData = keyscanPipe.fileHandleForReading.readDataToEndOfFile()
    let keyLine = String(decoding: keyData, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .first { !$0.isEmpty && !$0.contains("#") } ?? ""
    if !keyLine.isEmpty {
        try (knownHostsOriginal + (knownHostsOriginal.hasSuffix("\n") || knownHostsOriginal.isEmpty ? "" : "\n") + keyLine + "\n")
            .write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }
    defer {
        sshd.terminate(); sshd.waitUntilExit()
        if sshd.isRunning { kill(sshd.processIdentifier, SIGKILL) }
        try? (knownHostsOriginal.isEmpty ? Data() : Data(knownHostsOriginal.utf8))
            .write(to: knownHostsURL, options: .atomic)
        try? FileManager.default.removeItem(at: root)
    }
    try await Task.sleep(for: .seconds(1))

    let host = SSHHost(name: "sftp-fixture", address: "127.0.0.1", username: NSUserName(),
        port: port, authentication: .privateKey, privateKeyPath: home.appendingPathComponent("client_ed25519").path)
    let entries = try await SFTPService.list(host: host, path: listing.path)
    let names = Set(entries.map(\.name))
    #expect(names.contains("visible.txt"))
    #expect(names.contains(".hidden-file"))
    #expect(names.contains(".hidden-dir"))
}
