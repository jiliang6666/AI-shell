import AppKit
import Darwin
import Foundation
import NetFS
import Observation

enum SMBMountMode: String, Codable, CaseIterable, Sendable {
    case system, custom
}

struct SMBIdentity: Equatable, Hashable, Sendable {
    let server: String
    let port: Int
    let share: String
    let username: String

    init(url: URL, username: String) {
        server = (url.host ?? "").lowercased()
        port = url.port ?? 445
        share = url.path.split(separator: "/").first.map(String.init) ?? ""
        self.username = username.replacingOccurrences(of: "\\", with: ";").lowercased()
    }
}

struct SMBVolume: Equatable, Sendable {
    let path: String
    let source: String
    let generation: String
    let readOnly: Bool

    var identity: SMBIdentity? {
        guard let url = URL(string: source.hasPrefix("//") ? "smb:" + source : source),
              url.host != nil else { return nil }
        return SMBIdentity(url: url, username: url.user?.removingPercentEncoding ?? "")
    }

    static func all() -> [SMBVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var values = Array(repeating: statfs(), count: Int(count) + 16)
        let used = values.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        return values.prefix(max(0, Int(used))).compactMap { original in
            var value = original
            let type = withUnsafePointer(to: &value.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            guard type == "smbfs" else { return nil }
            let path = withUnsafePointer(to: &value.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let source = withUnsafePointer(to: &value.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return SMBVolume(path: path, source: source,
                             generation: "\(value.f_fsid.val.0):\(value.f_fsid.val.1)",
                             readOnly: value.f_flags & UInt32(MNT_RDONLY) != 0)
        }
    }
}

struct SMBMountFailure: LocalizedError, Sendable {
    enum Recovery: Sendable { case directory, systemMount, networkSettings, retry }
    let message: String
    var recovery: Recovery = .retry
    var path: String? = nil
    var errorDescription: String? { message }
}

enum SMBPathPolicy {
    static func contains(_ path: String, in root: String) -> Bool {
        let child = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.starts(with: base)
    }

    static func customMountPath(_ raw: String) throws -> String {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw SMBMountFailure(message: "请选择绝对路径的空文件夹。", recovery: .directory)
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let path = url.path
        let resolved = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == resolved else {
            throw SMBMountFailure(message: "挂载位置不能是符号链接，请选择实际的空文件夹。", recovery: .directory, path: path)
        }
        guard !["/", home, "/Users", "/private", "/tmp", "/private/tmp"].contains(path) else {
            throw SMBMountFailure(message: "不能把此根目录作为挂载位置，请选择其中的空文件夹。", recovery: .directory, path: path)
        }
        let withinUserTemporaryDirectory = contains(path, in: FileManager.default.temporaryDirectory.path)
        guard withinUserTemporaryDirectory || !["/Volumes", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/var"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw SMBMountFailure(message: "“\(path)”由 macOS 管理，应用无法直接创建挂载文件夹。请使用系统挂载，或选择个人目录中的空文件夹。", recovery: .systemMount, path: path)
        }
        return path
    }

    static func prepareDirectory(_ raw: String, fileManager: FileManager = .default) throws -> String {
        let path = try customMountPath(raw)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SMBMountFailure(message: "“\(path)”是文件，不能用于挂载。请选择可读写的空文件夹。", recovery: .directory, path: path)
            }
        } else {
            do { try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true) }
            catch {
                throw SMBMountFailure(message: "无法创建挂载文件夹“\(path)”。请先在访达中创建这个空文件夹，确认当前用户可以读写后重试，也可以选择其他文件夹。", recovery: .directory, path: path)
            }
        }
        guard fileManager.isReadableFile(atPath: path), fileManager.isWritableFile(atPath: path), fileManager.isExecutableFile(atPath: path) else {
            throw SMBMountFailure(message: "当前用户没有权限使用“\(path)”作为挂载位置。请在访达“显示简介 → 共享与权限”中检查权限，或选择可读写的空文件夹。", recovery: .directory, path: path)
        }
        guard try fileManager.contentsOfDirectory(atPath: path).isEmpty else {
            throw SMBMountFailure(message: "“\(path)”不是空文件夹，请选择其他位置。现有内容不会被覆盖。", recovery: .directory, path: path)
        }
        return path
    }
}

struct SMBFileContext: Equatable, Sendable {
    let profileID: UUID
    let name: String
    let volume: SMBVolume
    let root: String
    let initialPath: String

    init(profileID: UUID, name: String, volume: SMBVolume, root: String, initialPath: String? = nil) {
        self.profileID = profileID
        self.name = name
        self.volume = volume
        self.root = root
        self.initialPath = initialPath ?? root
    }

    func validate(_ path: String, writing: Bool = false, volumes: [SMBVolume]? = nil) throws {
        guard (volumes ?? SMBVolume.all()).contains(volume) else {
            throw SMBMountFailure(message: "共享已卸载或挂载已变化，请重新打开文件页。操作未写入本机目录。")
        }
        guard SMBPathPolicy.contains(path, in: root) else {
            throw SMBMountFailure(message: "路径不属于当前 SMB 文件夹，请返回共享根目录。")
        }
        if writing, volume.readOnly {
            throw SMBMountFailure(message: "此共享以只读方式挂载，不能修改文件。")
        }
    }
    func lease(_ path: String, writing: Bool = false) throws -> SMBFileLease {
        try validate(path, writing: writing)
        let fd = open(volume.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw SMBMountFailure(message: "无法打开共享根目录，请检查网络并重新挂载。") }
        var info = statfs()
        let actualGeneration = fstatfs(fd, &info) == 0 ? "\(info.f_fsid.val.0):\(info.f_fsid.val.1)" : ""
        guard actualGeneration == volume.generation else {
            Darwin.close(fd)
            throw SMBMountFailure(message: "共享挂载已变化，文件操作已停止。")
        }
        return SMBFileLease(descriptor: fd)
    }

}

// Kept alive for the duration of a worker's I/O. An ordinary unmount cannot
// silently replace the mounted filesystem while this directory is in use.
final class SMBFileLease {
    private var descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}

enum SMBMountService {
    static func isMounted(at path: String) -> Bool { SMBVolume.all().contains { $0.path == path } }

    static func url(for profile: SMBMountProfile) throws -> URL {
        let raw = profile.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = raw.contains("://") ? raw : "smb://" + raw
        guard var components = URLComponents(string: address), components.scheme == "smb",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw SMBMountFailure(message: "服务器地址无效。请填写主机名、IP 或主机名:端口，不要包含账号、密码和共享路径。")
        }
        let parts = profile.share.split(separator: "/").map(String.init)
        guard parts.count == 1, parts[0] != ".", parts[0] != "..", !parts[0].contains("\0") else {
            throw SMBMountFailure(message: "请分别填写共享名称和初始子目录。共享名称不能包含“/”。")
        }
        let directories = profile.initialSubdirectory.split(separator: "/").map(String.init)
        guard !directories.contains(".."), !profile.initialSubdirectory.hasPrefix("/"), !profile.initialSubdirectory.contains("\0") else {
            throw SMBMountFailure(message: "初始子目录必须位于共享内，不能包含“..”或绝对路径。")
        }
        components.path = "/" + parts[0]
        guard let result = components.url else { throw SMBMountFailure(message: "无法生成 SMB 共享地址。") }
        return result
    }

    static func identity(for profile: SMBMountProfile) throws -> SMBIdentity {
        SMBIdentity(url: try url(for: profile), username: profile.username)
    }

    static func matching(_ actual: SMBIdentity?, _ expected: SMBIdentity, aliases: (String) -> Set<String> = SMBHostAliases.shared.known) -> Bool {
        guard let actual, actual.port == expected.port, actual.share.caseInsensitiveCompare(expected.share) == .orderedSame,
              actual.username == expected.username else { return false }
        return actual.server == expected.server || !aliases(actual.server).isDisjoint(with: aliases(expected.server))
    }

    static func volume(for profile: SMBMountProfile, in volumes: [SMBVolume] = SMBVolume.all()) -> SMBVolume? {
        guard let identity = try? identity(for: profile) else { return nil }
        let matches = volumes.filter { matching($0.identity, identity) }
        if profile.mountMode == .custom { return matches.first { $0.path == profile.mountPath } }
        // Multiple identical shares are ambiguous: never choose a random volume to unmount.
        return matches.count == 1 ? matches.first : nil
    }

    static func fileContext(profile: SMBMountProfile, volume: SMBVolume) -> SMBFileContext {
        let initialPath = profile.initialSubdirectory.isEmpty ? volume.path
            : (volume.path as NSString).appendingPathComponent(profile.initialSubdirectory)
        return SMBFileContext(profileID: profile.id, name: profile.name, volume: volume, root: volume.path, initialPath: initialPath)
    }

    static func mount(_ profile: SMBMountProfile) async throws -> [String] {
        let url = try url(for: profile)
        let key = try identity(for: profile)
        let snapshot = SMBVolume.all()
        await Task.detached {
            SMBHostAliases.shared.resolve(key.server)
            for host in Set(snapshot.compactMap { $0.identity?.server }) { SMBHostAliases.shared.resolve(host) }
        }.value
        if let existing = volume(for: profile) { return [existing.path] }
        guard !SMBVolume.all().contains(where: { matching($0.identity, key) }) else {
            throw SMBMountFailure(message: "此共享已在其他位置挂载，无法同时使用指定的自定义位置。可选择“使用系统挂载”复用已有连接；若必须使用自定义位置，请先自行确认并卸载旧卷。", recovery: .systemMount)
        }
        // Retry the best-effort prompt if the app was first opened offline.
        await LocalNetworkAccess.request()
        let path: String?
        if profile.mountMode == .custom {
            path = try await Task.detached { try SMBPathPolicy.prepareDirectory(profile.mountPath) }.value
        } else { path = nil }
        let request = SMBNativeMountRequest()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(60)); request.cancel(timeout: true) }
            catch { }
        }
        defer { timeout.cancel() }
        let paths = try await withTaskCancellationHandler {
            try await request.start(url: url, path: path, profile: profile)
        } onCancel: { request.cancel(timeout: false) }
        guard let result = volume(for: profile), paths.isEmpty || paths.contains(result.path) else {
            throw SMBMountFailure(message: "系统已完成挂载请求，但无法核实对应共享及实际目录。请刷新连接状态，勿重复挂载。")
        }
        return [result.path]
    }

    static func unmount(_ profile: SMBMountProfile, expected: SMBVolume? = nil) throws {
        guard let actual = volume(for: profile) else {
            throw SMBMountFailure(message: "无法确认当前共享的挂载身份，请先刷新状态。")
        }
        if let expected, expected != actual { throw SMBMountFailure(message: "挂载已变化，卸载已停止。请重新确认。") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/umount")
        task.arguments = [actual.path]
        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        let diagnostic = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, !SMBVolume.all().contains(actual) else {
            let busy = String(decoding: diagnostic, as: UTF8.self).localizedCaseInsensitiveContains("busy")
            throw SMBMountFailure(message: busy ? "共享正在使用中。请关闭其中的文件或访达窗口后重试。" : "共享卸载失败，请关闭其中的文件后重试。")
        }
    }

    static func failure(status: Int32) -> SMBMountFailure {
        switch status {
        case -128: return SMBMountFailure(message: "已取消系统挂载操作。")
        case Int32(EAUTH): return SMBMountFailure(message: "SMB 认证未完成（系统状态 80）。请在编辑连接资料中核对已保存的账号密码、用户名所属的域，并确认服务器允许该账号通过 SMB 登录。")
        case Int32(EACCES), Int32(EPERM): return SMBMountFailure(message: "SMB 访问被拒绝。请检查已保存的账号密码、共享权限及挂载目录权限（系统状态 \(status)）。")
        case Int32(EEXIST): return SMBMountFailure(message: "共享或挂载位置已存在。请刷新状态检查现有连接，可改用系统挂载，或选择其他空文件夹（系统状态 17）。", recovery: .systemMount)
        case Int32(ENOENT): return SMBMountFailure(message: "找不到共享或挂载位置，请检查共享名称和目录（系统状态 \(status)）。")
        case Int32(ETIMEDOUT), Int32(EHOSTUNREACH), Int32(ENETUNREACH): return SMBMountFailure(message: "无法连接 SMB 服务器，请检查网络和服务器状态，并确认“系统设置 → 隐私与安全 → 本地网络”已允许栈桥访问（系统状态 \(status)）。", recovery: .networkSettings)
        case -5999: return SMBMountFailure(message: "服务器限制了此账号的 SMB 访问，请检查账号权限。")
        default: return SMBMountFailure(message: "SMB 挂载未完成，请检查服务器、账号及共享配置（系统状态 \(status)）。")
        }
    }
}

// All continuation/request state is protected by the lock. Native callbacks may arrive on
// another queue, and cancellation must resume exactly once even when no callback follows.
private final class SMBNativeMountRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var requestID: AsyncRequestID?
    private var canceled = false
    private var finished = false

    func start(url: URL, path: String?, profile: SMBMountProfile) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if canceled {
                lock.unlock()
                continuation.resume(throwing: SMBMountFailure(message: "挂载已取消，请刷新状态后重试。"))
                return
            }
            self.continuation = continuation
            lock.unlock()
            let options = CFDictionaryCreateMutableCopy(nil, 0, [kNAUIOptionKey as String: kNAUIOptionNoUI] as CFDictionary)!
            let mountOptions = CFDictionaryCreateMutableCopy(nil, 0, [kNetFSMountAtMountDirKey as String: true] as CFDictionary)!
            var id: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, path.map { URL(fileURLWithPath: $0) as CFURL },
                                           profile.username as CFString, profile.password as CFString,
                                           options, path == nil ? nil : mountOptions, &id,
                                           DispatchQueue.global(qos: .userInitiated)) { [self] status, _, points in
                finish(status == 0 ? .success((points as? [String]) ?? []) : .failure(SMBMountService.failure(status: status)))
            }
            lock.lock()
            requestID = finished ? nil : id
            let shouldCancel = canceled
            lock.unlock()
            if shouldCancel, let id { _ = NetFSMountURLCancel(id) }
            if status != 0 { finish(.failure(SMBMountService.failure(status: status))) }
        }
    }

    func cancel(timeout: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        canceled = true
        let id = requestID
        lock.unlock()
        if let id { _ = NetFSMountURLCancel(id) }
        finish(.failure(timeout
            ? SMBMountFailure(message: "挂载等待超过 60 秒。请检查网络，并确认“系统设置 → 隐私与安全 → 本地网络”已允许栈桥访问；同时核对已保存的账号密码，刷新状态确认是否已挂载。", recovery: .networkSettings)
            : SMBMountFailure(message: "挂载已取消，请刷新状态确认共享是否仍已连接。")))
    }

    private func finish(_ result: Result<[String], Error>) {
        lock.lock()
        let saved = continuation
        continuation = nil
        finished = true
        requestID = nil
        lock.unlock()
        saved?.resume(with: result)
    }
}

@MainActor @Observable
final class SMBMountCoordinator {
    static let shared = SMBMountCoordinator()
    var volumes: [SMBVolume] = []
    var busy: Set<UUID> = []
    var failures: [UUID: SMBMountFailure] = [:]
    var refreshGeneration = 0
    private var operations: [SMBIdentity: Task<[String], Error>] = [:]
    private var observers: [NSObjectProtocol] = []
    private let snapshot: @Sendable () -> [SMBVolume]
    private let mountAction: @Sendable (SMBMountProfile) async throws -> [String]
    private var operationPaths: [SMBIdentity: String] = [:]
    private var unmounting: Set<SMBIdentity> = []
    private var editors: [UUID: SMBFileContext] = [:]

    func beginEditing(token: UUID, context: SMBFileContext) { editors[token] = context }
    func endEditing(token: UUID) { editors[token] = nil }
    func hasOpenEditor(_ profile: SMBMountProfile) -> Bool {
        editors.values.contains { $0.profileID == profile.id || $0.volume == volume(for: profile) }
    }

    init(registerSystemEvents: Bool = true,
         snapshot: @escaping @Sendable () -> [SMBVolume] = SMBVolume.all,
         mountAction: @escaping @Sendable (SMBMountProfile) async throws -> [String] = SMBMountService.mount) {
        self.snapshot = snapshot
        self.mountAction = mountAction
        if registerSystemEvents {
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        }
        refresh()
    }

    func refresh() {
        volumes = snapshot(); refreshGeneration += 1
        let hosts = Set(volumes.compactMap { $0.identity?.server })
        guard !hosts.isEmpty else { return }
        Task {
            await Task.detached { for host in hosts { SMBHostAliases.shared.resolve(host) } }.value
            self.volumes = self.snapshot(); self.refreshGeneration += 1
        }
    }
    func volume(for profile: SMBMountProfile) -> SMBVolume? {
        _ = refreshGeneration
        return SMBMountService.volume(for: profile, in: volumes)
    }
    func isUnmounting(_ profile: SMBMountProfile) -> Bool {
        guard let key = try? SMBMountService.identity(for: profile) else { return false }
        return unmounting.contains(key)
    }

    func label(for profile: SMBMountProfile) -> String {
        if isUnmounting(profile) { return "卸载中…" }
        if busy.contains(profile.id) { return "等待系统操作…" }
        if volume(for: profile) != nil { return "已挂载" }
        return failures[profile.id] == nil ? "未挂载" : "连接失败"
    }

    func mount(_ profile: SMBMountProfile) async throws -> [String] {
        let key = try SMBMountService.identity(for: profile)
        guard !unmounting.contains(key) else { throw SMBMountFailure(message: "此共享正在卸载，请稍后重试。") }
        let requestedPath = profile.mountMode == .system ? "system" : profile.mountPath
        if let prior = operationPaths[key], prior != requestedPath {
            throw SMBMountFailure(message: "此共享正按另一挂载位置连接，请等待完成后再操作。")
        }
        busy.insert(profile.id)
        failures[profile.id] = nil
        defer { busy.remove(profile.id); refresh() }
        let task: Task<[String], Error>
        if let existing = operations[key] { task = existing }
        else {
            let action = mountAction
            task = Task { try await action(profile) }
            operations[key] = task
            operationPaths[key] = requestedPath
        }
        do {
            let result = try await task.value
            operations[key] = nil
            operationPaths[key] = nil
            return result
        } catch {
            operations[key] = nil
            operationPaths[key] = nil
            failures[profile.id] = error as? SMBMountFailure ?? SMBMountFailure(message: error.localizedDescription)
            throw error
        }
    }

    func cancel(_ profile: SMBMountProfile) {
        if let key = try? SMBMountService.identity(for: profile) { operations[key]?.cancel() }
    }

    func unmount(_ profile: SMBMountProfile) async throws {
        let key = try SMBMountService.identity(for: profile)
        guard !busy.contains(profile.id), operations[key] == nil, !unmounting.contains(key) else {
            throw SMBMountFailure(message: "此共享仍有挂载或卸载操作，请等待完成。")
        }
        guard let volume = volume(for: profile) else { throw SMBMountFailure(message: "共享没有可确认的挂载，请刷新状态。") }
        guard !hasOpenEditor(profile) else { throw SMBMountFailure(message: "此共享仍有打开的文件编辑器，请先保存或关闭，避免丢失修改。") }
        unmounting.insert(key)
        defer { unmounting.remove(key) }
        busy.insert(profile.id)
        failures[profile.id] = nil
        defer { busy.remove(profile.id); refresh() }
        do { try await Task.detached { try SMBMountService.unmount(profile, expected: volume) }.value }
        catch {
            failures[profile.id] = error as? SMBMountFailure ?? SMBMountFailure(message: error.localizedDescription)
            throw error
        }
    }
}

// DNS answers are only used with matching port, account and share. The lock
// protects this short-lived cache across filesystem workers and the UI actor.
final class SMBHostAliases: @unchecked Sendable {
    static let shared = SMBHostAliases()
    private let lock = NSLock()
    private var values: [String: (Date, Set<String>)] = [:]

    private func numericAddress(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
    }

    func known(_ host: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let entry = values[host], entry.0 > Date() { return entry.1.union([host]) }
        return [host]
    }

    func resolve(_ host: String) {
        lock.lock()
        let cached = values[host].map { $0.0 > Date() } ?? false
        lock.unlock()
        guard !cached else { return }
        var result: Set<String> = [host]
        if host.hasSuffix("._smb._tcp.local") {
            let name = String(host.dropLast("._smb._tcp.local".count))
            let service = NetService(domain: "local.", type: "_smb._tcp.", name: name)
            let delegate = SMBServiceResolution()
            service.delegate = delegate
            service.resolve(withTimeout: 3)
            let deadline = Date().addingTimeInterval(3.5)
            while !delegate.done && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if let name = service.hostName { result.insert(name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
            for address in service.addresses ?? [] {
                address.withUnsafeBytes { bytes in
                    guard let pointer = bytes.baseAddress else { return }
                    if let value = numericAddress(pointer.assumingMemoryBound(to: sockaddr.self), length: socklen_t(address.count)) {
                        result.insert(value)
                    }
                }
            }
            service.stop()
        } else {
            var addresses: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, nil, &addresses) == 0 {
                var cursor = addresses
                while let address = cursor {
                    if let value = numericAddress(address.pointee.ai_addr, length: address.pointee.ai_addrlen) {
                        result.insert(value)
                    }
                    cursor = address.pointee.ai_next
                }
                freeaddrinfo(addresses)
            }
        }
        lock.lock(); values[host] = (Date().addingTimeInterval(result.count > 1 ? 300 : 15), result); lock.unlock()
    }
}

private final class SMBServiceResolution: NSObject, NetServiceDelegate {
    var done = false
    func netServiceDidResolveAddress(_ sender: NetService) { done = true }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { done = true }
}
