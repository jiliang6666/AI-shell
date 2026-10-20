import Foundation

/// A snippet of terminal or file content that the user explicitly attached to
/// the next AI message. The source label is always carried along so the model
/// and the transcript can tell which host a snippet came from.
struct AIQuote: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: String
    var source: String
    var text: String

    var displayLabel: String { kind.isEmpty ? source : "\(kind) · \(source)" }
}

enum FileOperationError: LocalizedError, Sendable {
    case invalidName(String)
    case notEmptyDirectory(String)
    case notFound(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let message): return message
        case .notEmptyDirectory(let message): return message
        case .notFound(let message): return message
        case .unsupported(let message): return message
        }
    }
}

enum FileNamePolicy {
    /// Rejects names that would escape the current directory or hide the target.
    static func validate(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileOperationError.invalidName("名称不能为空。") }
        guard !name.contains("/") && !name.contains("\0") else {
            throw FileOperationError.invalidName("名称不能包含“/”。")
        }
        guard name != "." && name != ".." else {
            throw FileOperationError.invalidName("“.”和“..”不是有效名称。")
        }
        return name
    }

    /// Appends " 2", " 3"… before the extension until `exists` reports a free name.
    static func uniqueName(for rawName: String, exists: (String) -> Bool) -> String {
        guard exists(rawName) else { return rawName }
        let value = rawName as NSString
        let pathExtension = value.pathExtension
        let base = value.deletingPathExtension
        var counter = 2
        while true {
            let candidate = pathExtension.isEmpty
                ? "\(base) \(counter)"
                : "\(base) \(counter).\(pathExtension)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
}

enum FileTextHeuristics {
    /// Cheap check used before offering a file in the text editor. Binary files
    /// are refused instead of being silently rewritten with replacement characters.
    static func isProbablyText(_ data: Data) -> Bool {
        let sample = data.prefix(8_000)
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }
}

enum LocalFileOperations {
    static func createDirectory(at path: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    static func writeText(_ text: String, to path: String, fileManager: FileManager = .default) throws {
        guard let data = text.data(using: .utf8) else {
            throw FileOperationError.unsupported("文本无法转换成 UTF-8。")
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func move(_ path: String, to destination: String, fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: destination) else {
            throw FileOperationError.invalidName("目标名称已存在。")
        }
        try fileManager.moveItem(atPath: path, toPath: destination)
    }

    /// Only empty directories are removed, matching what `sftp`/`rmdir` can do
    /// on a remote host. Refusing a recursive delete keeps the two targets honest.
    static func remove(_ path: String, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FileOperationError.notFound("找不到 \(path)。")
        }
        if isDirectory.boolValue {
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            guard contents.isEmpty else {
                throw FileOperationError.notEmptyDirectory("目录不是空的，请先删除其中的内容。")
            }
            try fileManager.removeItem(atPath: path)
        } else {
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Copies a file next to `directory`, appending a counter when the name is taken.
    @discardableResult
    static func copy(_ source: String, into directory: String, fileManager: FileManager = .default) throws -> String {
        let name = try FileNamePolicy.validate(URL(fileURLWithPath: source).lastPathComponent)
        let destination = try uniqueDestination(for: name, in: directory, fileManager: fileManager)
        try fileManager.copyItem(atPath: source, toPath: destination)
        return destination
    }

    /// Copies a file to an exact destination, appending a counter when needed.
    @discardableResult
    static func copy(_ source: String, to destination: String, fileManager: FileManager = .default) throws -> String {
        let directory = (destination as NSString).deletingLastPathComponent
        let name = try FileNamePolicy.validate((destination as NSString).lastPathComponent)
        let target = try uniqueDestination(for: name, in: directory, fileManager: fileManager)
        try fileManager.copyItem(atPath: source, toPath: target)
        return target
    }

    static func uniqueDestination(
        for name: String,
        in directory: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let trimmed = directory.isEmpty ? "." : directory
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory) else {
            throw FileOperationError.notFound("找不到目录 \(trimmed)。")
        }
        let resolved = FileNamePolicy.uniqueName(for: name) { candidate in
            fileManager.fileExists(atPath: (trimmed as NSString).appendingPathComponent(candidate))
        }
        return (trimmed as NSString).appendingPathComponent(resolved)
    }
}

enum SFTPService {
    /// Progress lines and prompt echoes from the interactive `sftp` client are
    /// not part of the command result and must be removed before parsing.
    static func cleanedOutput(_ output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .filter { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("sftp>") else { return false }
                guard !line.hasPrefix("Connected to ") else { return false }
                guard !line.hasPrefix("Connection to ") || !line.contains("closed") else { return false }
                guard !line.hasPrefix("Could not chdir") else { return false }
                guard !line.isEmpty else { return false }
                return true
            }
            .joined(separator: "\n")
    }

    static func list(host: SSHHost, path: String) async throws -> [RemoteFileEntry] {
        let resolved = try await resolve(host: host, path: path)
        let output = cleanedOutput(try await run(host: host, commands: "ls -la \(quote(resolved))\nquit\n"))
        return output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard line.first == "d" || line.first == "-" || line.first == "l" else { return nil }
            let columns = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard columns.count == 9 else { return nil }
            // `sftp ls -la <absolute-path>` echoes the full path in the name
            // column; the visibility policy needs the bare file name.
            let fullName = String(columns[8])
            let name = (fullName as NSString).lastPathComponent
            guard name != ".", name != ".." else { return nil }
            let size = Int64(columns[4])
            return RemoteFileEntry(name: name, isDirectory: line.first == "d", id: joined(path, name), size: size)
        }
    }

    static func read(host: SSHHost, path: String) async throws -> String {
        let resolved = try await resolve(host: host, path: path)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftTerminal-\(UUID().uuidString).preview")
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await run(host: host, commands: "get \(quote(resolved)) \(quote(local.path))\nquit\n")
        let data = try Data(contentsOf: local)
        return String(decoding: data.prefix(1_000_000), as: UTF8.self)
    }

    static func makeDirectory(host: SSHHost, path: String) async throws {
        let resolved = try await resolve(host: host, path: path)
        _ = try await run(host: host, commands: "mkdir \(quote(resolved))\nquit\n")
    }

    static func writeText(_ text: String, host: SSHHost, path: String) async throws {
        let resolved = try await resolve(host: host, path: path)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftTerminal-\(UUID().uuidString).upload")
        defer { try? FileManager.default.removeItem(at: local) }
        try Data(text.utf8).write(to: local, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
        _ = try await run(host: host, commands: "put \(quote(local.path)) \(quote(resolved))\nquit\n")
    }

    static func move(host: SSHHost, path: String, to destination: String) async throws {
        let resolved = try await resolve(host: host, path: path)
        let target = try await resolve(host: host, path: destination)
        _ = try await run(host: host, commands: "rename \(quote(resolved)) \(quote(target))\nquit\n")
    }

    static func remove(host: SSHHost, path: String, isDirectory: Bool) async throws {
        let resolved = try await resolve(host: host, path: path)
        _ = try await run(host: host, commands: "\(isDirectory ? "rmdir" : "rm") \(quote(resolved))\nquit\n")
    }

    static func upload(host: SSHHost, localPath: String, directory: String) async throws -> String {
        let resolvedDirectory = try await resolve(host: host, path: directory)
        let name = URL(fileURLWithPath: localPath).lastPathComponent
        let destination = joined(resolvedDirectory, name)
        _ = try await run(host: host, commands: "put \(quote(localPath)) \(quote(destination))\nquit\n")
        return destination
    }

    static func download(host: SSHHost, path: String, to localPath: String) async throws {
        let resolved = try await resolve(host: host, path: path)
        _ = try await run(host: host, commands: "get \(quote(resolved)) \(quote(localPath))\nquit\n")
    }

    static func joined(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// `sftp` does not run a shell, so a leading `~` is expanded here once with
    /// the account's real home directory instead of being guessed.
    private static func resolve(host: SSHHost, path: String) async throws -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let output = cleanedOutput(try await run(host: host, commands: "pwd\nquit\n"))
        let home = output.split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = String(line)
                guard let range = text.range(of: "Remote working directory:") else { return nil }
                let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            .last
        guard let home else {
            throw FileOperationError.notFound("无法确认远端主目录，请在路径中填写绝对路径。")
        }
        return path == "~" ? home : home + String(path.dropFirst())
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(host: SSHHost, commands: String) async throws -> String {
        let state = SFTPProcessState()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .userInitiated) {
            let task = state.process
            let input = Pipe()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            // Batch mode (`-b`) is intentionally avoided: OpenSSH stops using
            // the askpass helper in that mode, so DSM rejects the connection
            // before the subsystem starts. Commands are fed through stdin
            // instead and the interactive prompt echoes are filtered out.
            var arguments = ["-P", String(host.port), "-oStrictHostKeyChecking=yes", "-oConnectTimeout=15"]
            switch host.authentication {
            case .password:
                arguments += [
                    "-oPreferredAuthentications=password,keyboard-interactive",
                    "-oPubkeyAuthentication=no",
                    "-oNumberOfPasswordPrompts=1"
                ]
            case .privateKey:
                arguments += ["-oPreferredAuthentications=publickey", "-i", (host.privateKeyPath as NSString).expandingTildeInPath]
            case .agent:
                arguments += ["-oPreferredAuthentications=publickey"]
            }
            arguments += ["\(host.username)@\(host.address)"]
            task.arguments = arguments
            task.standardInput = input
            task.standardOutput = output
            task.standardError = output
            var environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
            if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = socket }
            var transientCredential: URL?
            if host.authentication == .password, !host.password.isEmpty {
                let helper = try SSHHostStore.ensureAskpassHelper()
                let credential = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftTerminal-\(UUID().uuidString).askpass")
                try Data(host.password.utf8).write(to: credential, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credential.path)
                transientCredential = credential
                environment["SSH_ASKPASS"] = helper.path
                environment["SSH_ASKPASS_REQUIRE"] = "force"
                environment["DISPLAY"] = "SwiftTerminal"
                environment["SWIFTTERMINAL_SSH_PASSWORD_FILE"] = credential.path
            }
            task.environment = environment
            defer { if let transientCredential { try? FileManager.default.removeItem(at: transientCredential) } }
            try state.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                state.timeoutIfRunning()
            }
            input.fileHandleForWriting.write(Data(commands.utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if state.didTimeOut { throw FileOperationError.unsupported("SFTP 操作超过 180 秒，已停止。") }
            let result = String(decoding: data, as: UTF8.self)
            guard task.terminationStatus == 0 else {
                if result.localizedCaseInsensitiveContains("permission denied"), host.authentication == .password {
                    throw FileOperationError.unsupported("远端拒绝认证。请在文件页输入该主机的 SSH 密码；若密码确认无误，请检查 NAS 的 SFTP 与账号权限。")
                }
                throw NSError(domain: "SwiftTerminal.SFTP", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result.isEmpty ? "SFTP 操作失败。请先在 SSH 终端确认主机指纹。" : result])
            }
            return result
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            state.cancel()
        }
    }
}

final class SFTPProcessState: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    func timeoutIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        timedOut = true
        process.terminate()
    }
}

/// Thin switch used by the file page so local and SSH targets behave the same way.
enum WorkspaceFileService {
    static func createDirectory(host: SSHHost?, path: String, smb: SMBFileContext? = nil) async throws {
        if let host {
            try await SFTPService.makeDirectory(host: host, path: path)
        } else {
            try await Task.detached { let lease = try smb?.lease(path, writing: true); defer { lease?.close() }; try LocalFileOperations.createDirectory(at: path) }.value
        }
    }

    static func writeText(_ text: String, host: SSHHost?, path: String, smb: SMBFileContext? = nil) async throws {
        if let host {
            try await SFTPService.writeText(text, host: host, path: path)
        } else {
            try await Task.detached { let lease = try smb?.lease(path, writing: true); defer { lease?.close() }; try LocalFileOperations.writeText(text, to: path) }.value
        }
    }

    @discardableResult
    static func rename(host: SSHHost?, path: String, to name: String, smb: SMBFileContext? = nil) async throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let validated = try FileNamePolicy.validate(name)
        let destination = (directory as NSString).appendingPathComponent(validated)
        guard destination != path else { return path }
        if let host {
            try await SFTPService.move(host: host, path: path, to: destination)
        } else {
            try await Task.detached { let lease = try smb?.lease(path, writing: true); defer { lease?.close() }; try smb?.validate(destination, writing: true); try LocalFileOperations.move(path, to: destination) }.value
        }
        return destination
    }

    static func remove(host: SSHHost?, path: String, isDirectory: Bool, smb: SMBFileContext? = nil) async throws {
        if let host {
            try await SFTPService.remove(host: host, path: path, isDirectory: isDirectory)
        } else {
            try await Task.detached { let lease = try smb?.lease(path, writing: true); defer { lease?.close() }; try LocalFileOperations.remove(path) }.value
        }
    }

    @discardableResult
    static func upload(host: SSHHost?, localPaths: [String], directory: String, smb: SMBFileContext? = nil) async throws -> [String] {
        var results: [String] = []
        for localPath in localPaths {
            if let host {
                results.append(try await SFTPService.upload(host: host, localPath: localPath, directory: directory))
            } else {
                results.append(try await Task.detached { let lease = try smb?.lease(directory, writing: true); defer { lease?.close() }; return try LocalFileOperations.copy(localPath, into: directory) }.value)
            }
        }
        return results
    }

    @discardableResult
    static func download(host: SSHHost?, path: String, to localPath: String, smb: SMBFileContext? = nil) async throws -> String {
        if let host {
            try await SFTPService.download(host: host, path: path, to: localPath)
            return localPath
        }
        return try await Task.detached { let lease = try smb?.lease(path); defer { lease?.close() }; return try LocalFileOperations.copy(path, to: localPath) }.value
    }
}
