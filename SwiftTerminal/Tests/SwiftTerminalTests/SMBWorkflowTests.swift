import Foundation
import Testing
@testable import SwiftTerminal

private func profile(share: String = "adult", path: String = "/Volumes/adult") -> SMBMountProfile {
    SMBMountProfile(name: "NAS 资料", server: "nas.example", share: share, username: "user", password: "", mountPath: path)
}

@Test("Legacy SMB profiles migrate system paths and split browsing subdirectories")
func smbLegacyMigration() throws {
    let value = profile(share: "extend2/domestic")
    var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    encoded.removeValue(forKey: "mountMode")
    encoded.removeValue(forKey: "initialSubdirectory")
    encoded["share"] = "extend2/domestic"
    let restored = try JSONDecoder().decode(SMBMountProfile.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(restored.id == value.id)
    #expect(restored.mountMode == .system)
    #expect(restored.share == "extend2")
    #expect(restored.initialSubdirectory == "domestic")
    #expect(restored.mountPath == "/Volumes/adult")
}

@Test("Saved SMB passwords survive profile encoding and decoding")
func smbSavedPasswordRoundTrip() throws {
    var value = profile()
    value.password = "saved-password-for-round-trip"
    let restored = try JSONDecoder().decode(SMBMountProfile.self, from: JSONEncoder().encode(value))
    #expect(restored.password == value.password)
}

@Test("SMB authentication errors retain their status and give recovery guidance")
func smbAuthenticationFailureGuidance() {
    let failure = SMBMountService.failure(status: Int32(EAUTH))
    #expect(failure.message.contains("80"))
    #expect(failure.message.contains("已保存的账号密码"))
    #expect(failure.message.contains("域"))
    #expect(failure.message.contains("编辑连接资料"))
}

@Test("SMB URLs encode special share names and never contain passwords")
func smbURLSafety() throws {
    var value = profile(share: "资料 #1")
    value.password = "not-in-url"
    let url = try SMBMountService.url(for: value)
    #expect(url.path == "/资料 #1")
    #expect(url.password == nil)
    #expect(!url.absoluteString.contains(value.password))
    value.initialSubdirectory = "../other"
    #expect(throws: SMBMountFailure.self) { try SMBMountService.url(for: value) }
}

@Test("SMB volume matching checks server, account, share and actual mount path")
func smbVolumeIdentity() throws {
    let volume = SMBVolume(path: "/Volumes/adult-1", source: "//user@nas.example/adult", generation: "1:2", readOnly: false)
    #expect(SMBMountService.volume(for: profile(), in: [volume]) == volume)
    var other = profile()
    other.username = "other"
    #expect(SMBMountService.volume(for: other, in: [volume]) == nil)
    other = profile(); other.server = "other.example"
    #expect(SMBMountService.volume(for: other, in: [volume]) == nil)
    other = profile(path: "/private/tmp/custom"); other.mountMode = .custom
    #expect(SMBMountService.volume(for: other, in: [volume]) == nil)
    let duplicate = SMBVolume(path: "/Volumes/adult-2", source: volume.source, generation: "3:4", readOnly: false)
    #expect(SMBMountService.volume(for: profile(), in: [volume, duplicate]) == nil)
}

@Test("System directories give actionable recovery rather than raw filesystem errors", arguments: ["/Volumes/adult", "/System/mount", "/usr/mount"])
func smbProtectedDirectoryRecovery(_ path: String) throws {
    do {
        _ = try SMBPathPolicy.customMountPath(path)
        Issue.record("A protected directory was accepted")
    } catch let error as SMBMountFailure {
        #expect(error.recovery == .systemMount)
        #expect(error.message.contains("系统挂载"))
        #expect(error.path == path)
    }
}

@Test("Custom mount directories reject existing files and nonempty folders without changing them")
func smbDirectoryConflict() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let item = root.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: item)
    #expect(throws: SMBMountFailure.self) { try SMBPathPolicy.prepareDirectory(item.path) }
    #expect(throws: SMBMountFailure.self) { try SMBPathPolicy.prepareDirectory(root.path) }
    #expect(try String(contentsOf: item, encoding: .utf8) == "keep")
    let empty = root.appendingPathComponent("empty")
    #expect(try SMBPathPolicy.prepareDirectory(empty.path) == empty.path)
}

@Test("SMB root boundaries reject prefix lookalikes and symlinks escaping the share")
func smbRootBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let share = root.appendingPathComponent("share")
    let other = root.appendingPathComponent("share-other")
    try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let link = share.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
    #expect(SMBPathPolicy.contains(share.appendingPathComponent("new.txt").path, in: share.path))
    #expect(!SMBPathPolicy.contains(other.path, in: share.path))
    #expect(!SMBPathPolicy.contains(link.path, in: share.path))
}

@Test("A changed mount generation and read-only volume block SMB writes")
func smbGenerationProtection() throws {
    let volume = SMBVolume(path: "/Volumes/test", source: "//user@nas.example/adult", generation: "old", readOnly: false)
    let context = SMBFileContext(profileID: UUID(), name: "Test", volume: volume, root: volume.path)
    #expect(throws: SMBMountFailure.self) { try context.validate("/Volumes/test/file", writing: true, volumes: []) }
    let next = SMBVolume(path: volume.path, source: volume.source, generation: "new", readOnly: false)
    #expect(throws: SMBMountFailure.self) { try context.validate("/Volumes/test/file", writing: true, volumes: [next]) }
    let readOnly = SMBVolume(path: volume.path, source: volume.source, generation: "old", readOnly: true)
    let readOnlyContext = SMBFileContext(profileID: UUID(), name: "Test", volume: readOnly, root: volume.path)
    #expect(throws: SMBMountFailure.self) { try readOnlyContext.validate("/Volumes/test/file", writing: true, volumes: [readOnly]) }
}

@Test("Unmounted SMB operations never write into the leftover local directory")
func smbLocalFallbackWriteBlocked() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let item = root.appendingPathComponent("keep.txt")
    try Data("original".utf8).write(to: item)
    let volume = SMBVolume(path: root.path, source: "//user@nas.example/adult", generation: "not-mounted", readOnly: false)
    let context = SMBFileContext(profileID: UUID(), name: "Test", volume: volume, root: root.path)
    await #expect(throws: SMBMountFailure.self) {
        try await WorkspaceFileService.writeText("wrong", host: nil, path: item.path, smb: context)
    }
    #expect(try String(contentsOf: item, encoding: .utf8) == "original")
}

@Test("A directory creation permission failure explains how to create an empty folder and retry")
func smbFriendlyCreationFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    do {
        _ = try SMBPathPolicy.prepareDirectory(root.appendingPathComponent("missing").path)
        Issue.record("Creating a folder in a nonwritable parent unexpectedly succeeded")
    } catch let error as SMBMountFailure {
        #expect(error.recovery == .directory)
        #expect(error.message.contains("创建这个空文件夹"))
        #expect(error.message.contains("重试"))
    }
}

@Test("Verified Bonjour aliases match an IP only when account, share and port also agree")
func smbVerifiedHostAlias() throws {
    var value = profile()
    value.server = "192.0.2.10"
    let expected = try SMBMountService.identity(for: value)
    let actual = SMBIdentity(url: try #require(URL(string: "smb://nas._smb._tcp.local/adult")), username: "user")
    let aliases: (String) -> Set<String> = { host in host == "nas._smb._tcp.local" ? [host, "192.0.2.10"] : [host] }
    #expect(SMBMountService.matching(actual, expected, aliases: aliases))
    let wrongAccount = SMBIdentity(url: try #require(URL(string: "smb://nas._smb._tcp.local/adult")), username: "other")
    #expect(!SMBMountService.matching(wrongAccount, expected, aliases: aliases))
    let wrongShare = SMBIdentity(url: try #require(URL(string: "smb://nas._smb._tcp.local/other")), username: "user")
    #expect(!SMBMountService.matching(wrongShare, expected, aliases: aliases))
    #expect(!SMBMountService.matching(actual, expected, aliases: { [$0] }))
}
