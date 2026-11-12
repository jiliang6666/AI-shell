import Foundation

enum AICommandScanPolicy {
    private static let maximumWrapperDepth = 8

    private struct Scan {
        var tool: String
        var paths: [String]
        var hasExplicitPath: Bool
        var hasTraversalBoundary: Bool
        var hasSelectionFilter: Bool
    }

    private struct CommandSegment {
        var words: [String]
        var readsFromPipeline: Bool
    }

    static func violation(
        for command: String,
        workingDirectory: String? = nil,
        workingDirectoryIsTrusted: Bool = false
    ) -> String? {
        let scanWorkingDirectory = workingDirectoryIsTrusted ? workingDirectory : nil
        for scan in scans(in: command, depth: 0) {
            for path in scan.paths {
                guard normalizedPath(path, workingDirectory: scanWorkingDirectory) != nil else {
                    return refusal(for: scan, target: "未明确的工作目录", dockerTree: false)
                }
                if let broadPath = broadTarget(path, workingDirectory: scanWorkingDirectory) {
                    return refusal(
                        for: scan,
                        target: broadPath,
                        dockerTree: isDockerStorageTree(broadPath)
                    )
                }
            }

            guard scan.hasExplicitPath else {
                return refusal(for: scan, target: "未指定的目录", dockerTree: false)
            }
            if scan.tool != "du",
               (!scan.hasTraversalBoundary || !scan.hasSelectionFilter) {
                return refusal(for: scan, target: scan.paths.first ?? "未指定的目录", dockerTree: false)
            }
        }
        return nil
    }

    private static func refusal(for scan: Scan, target: String, dockerTree: Bool) -> String {
        let duAdvice = scan.tool == "du"
            ? "`du -d/--max-depth` 只限制输出层级，不限制目录遍历。"
            : ""
        let dockerAdvice = dockerTree
            ? "Docker 存储请优先查询 `docker system df`。"
            : ""
        return """
        已拦截递归扫描（\(scan.tool)，目标：\(target)）。请先列出简短扫描计划，根据已有证据缩小到明确目录；优先查元数据，再做定点、带筛选条件的扫描。`find` 需要有效的非负 `-maxdepth` 和筛选条件；`rg` 需要 `--max-depth` 和搜索条件。\(duAdvice)\(dockerAdvice)
        """
    }

    private static func scans(in command: String, depth: Int) -> [Scan] {
        let segments = commandSegments(command)
        let substitutions = commandSubstitutions(in: command)
        let substitutionScans = substitutions.flatMap { scans(in: $0, depth: depth + 1) }
        let changesDirectory = segments.contains { segment in
            firstCommandIndex(in: segment.words).map { basename(segment.words[$0]) == "cd" } == true
        }
        let result = segments.flatMap {
            scans(in: $0.words, depth: depth, readsFromPipeline: $0.readsFromPipeline)
        } + substitutionScans
        guard changesDirectory else { return result }
        return result.map { scan in
            var changedScope = scan
            changedScope.paths = scan.paths.map { isAbsoluteOrHomePath($0) ? $0 : "$CHANGED_WORKING_DIRECTORY/\($0)" }
            return changedScope
        }
    }

    private static func scans(
        in inputWords: [String],
        depth: Int,
        readsFromPipeline: Bool = false
    ) -> [Scan] {
        let words = removingRedirections(inputWords)
        guard let commandIndex = firstCommandIndex(in: words) else { return [] }

        let command = basename(words[commandIndex]).lowercased()
        let arguments = Array(words.dropFirst(commandIndex + 1))
        if depth >= maximumWrapperDepth {
            return directScan(command, arguments: arguments) != nil || isCommandWrapper(command)
                ? [unresolvedScan(tool: command)]
                : []
        }
        let nestedDepth = depth + 1

        switch command {
        case "ssh":
            let remoteArguments = sshCommandArguments(arguments)
            guard !remoteArguments.isEmpty else { return [] }
            return scans(in: remoteArguments.joined(separator: " "), depth: nestedDepth).map { scan in
                var remoteScan = scan
                remoteScan.paths = scan.paths.map {
                    isAbsoluteOrHomePath($0) ? $0 : "$REMOTE_WORKING_DIRECTORY/\($0)"
                }
                return remoteScan
            }
        case "sudo", "doas":
            return scans(in: Array(arguments.dropFirst(wrapperCommandIndex(
                in: arguments,
                optionsWithValues: ["-u", "-g", "-h", "-p", "-r", "-t", "-C", "--user", "--group", "--host", "--prompt"]
            ))), depth: nestedDepth)
        case "timeout":
            return scans(in: timeoutCommand(arguments), depth: nestedDepth)
        case "sh", "bash", "zsh", "dash", "ksh", "fish":
            guard let script = shellCommand(arguments) else { return [] }
            return scans(in: script, depth: nestedDepth)
        case "env":
            let changesDirectory = arguments.contains { $0 == "-C" || $0 == "--chdir" || $0.hasPrefix("--chdir=") }
            let envArguments = Array(arguments.dropFirst(wrapperCommandIndex(
                in: arguments,
                optionsWithValues: ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]
            )))
            let commandArguments = envArguments.drop(while: { $0.contains("=") && !$0.hasPrefix("-") })
            let nestedScans = scans(in: Array(commandArguments), depth: nestedDepth)
            guard changesDirectory else { return nestedScans }
            return nestedScans.map { scan in
                var changedScope = scan
                changedScope.paths = scan.paths.map {
                    isAbsoluteOrHomePath($0) ? $0 : "$UNRESOLVED_ENV_CHDIR/\($0)"
                }
                return changedScope
            }
        case "xargs":
            let commandArguments = Array(arguments.dropFirst(wrapperCommandIndex(
                in: arguments,
                optionsWithValues: [
                    "-a", "--arg-file", "-d", "--delimiter", "-E", "--eof", "-I", "--replace",
                    "-i", "-n", "--max-args", "-P", "--max-procs", "--process-slot-var",
                ]
            )))
            let nestedScans = scans(in: commandArguments, depth: nestedDepth)
            return nestedScans.isEmpty ? [] : [unresolvedScan(tool: "xargs")]
        case "command", "exec", "nohup", "time", "nice", "ionice", "stdbuf", "setsid", "sshpass":
            if command == "command", arguments.contains("-v") || arguments.contains("-V") {
                return []
            }
            let optionValues: Set<String>
            switch command {
            case "nice": optionValues = ["-n", "--adjustment"]
            case "ionice": optionValues = ["-c", "-n", "-p", "--class", "--classdata", "--pid"]
            case "stdbuf": optionValues = ["-i", "-o", "-e"]
            case "sshpass": optionValues = ["-p", "-f", "-d", "-e"]
            default: optionValues = []
            }
            return scans(in: Array(arguments.dropFirst(wrapperCommandIndex(
                in: arguments,
                optionsWithValues: optionValues
            ))), depth: nestedDepth)
        default:
            return directScan(command, arguments: arguments, readsFromPipeline: readsFromPipeline).map { [$0] } ?? []
        }
    }

    private static func directScan(
        _ command: String,
        arguments: [String],
        readsFromPipeline: Bool = false
    ) -> Scan? {
        if arguments.contains("--help") || arguments.contains("--version") { return nil }
        switch command {
        case "find":
            return findScan(arguments)
        case "du":
            return duScan(arguments)
        case "rg":
            return ripgrepScan(arguments, readsFromPipeline: readsFromPipeline)
        case "grep":
            return grepScan(arguments, readsFromPipeline: readsFromPipeline)
        case "ls":
            return recursiveListScan(arguments)
        case "tree":
            return treeScan(arguments)
        case "fd", "fdfind":
            return fdScan(arguments)
        default:
            return nil
        }
    }

    private static func findScan(_ arguments: [String]) -> Scan? {
        var paths: [String] = []
        var expressionStarted = false

        for argument in arguments {
            if !expressionStarted,
               ["-H", "-L", "-P"].contains(argument) {
                continue
            }
            if !expressionStarted,
               argument.hasPrefix("-O") || argument.hasPrefix("-D") {
                continue
            }
            if !expressionStarted,
               argument.hasPrefix("-") || argument == "!" || argument == "(" {
                expressionStarted = true
            }
            if !expressionStarted {
                paths.append(argument)
            }
        }

        var bounded = false
        let filterOperators: Set<String> = [
            "-name", "-iname", "-type", "-size", "-mtime", "-mmin", "-newermt", "-path",
            "-ipath", "-regex", "-iregex", "-user", "-group", "-perm", "-empty", "-links",
            "-inum",
        ]
        let hasFilter = arguments.contains(where: { filterOperators.contains($0) })
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == "-maxdepth", arguments.indices.contains(index + 1),
               Int(arguments[index + 1]).map({ $0 >= 0 }) == true {
                bounded = true
            } else if argument.hasPrefix("-maxdepth="),
                      Int(argument.dropFirst("-maxdepth=".count)).map({ $0 >= 0 }) == true {
                bounded = true
            }
        }

        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "find",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: bounded,
            hasSelectionFilter: hasFilter
        )
    }

    private static func duScan(_ arguments: [String]) -> Scan? {
        let optionsWithValues: Set<String> = [
            "-d", "-t", "-I", "-X", "--max-depth", "--threshold", "--time", "--exclude",
            "--exclude-from", "--files0-from",
        ]
        let paths = positionalArguments(arguments, optionsWithValues: optionsWithValues)
        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "du",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: false,
            hasSelectionFilter: false
        )
    }

    private static func ripgrepScan(_ arguments: [String], readsFromPipeline: Bool) -> Scan? {
        var positionals: [String] = []
        var patternFromOption = false
        var filesMode = false
        var hasGlobFilter = false
        var bounded = false
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, argument == "--files" {
                filesMode = true
                index += 1
                continue
            }
            if !optionsEnded, argument == "--max-depth", arguments.indices.contains(index + 1) {
                bounded = Int(arguments[index + 1]).map({ $0 >= 0 }) == true
                index += 2
                continue
            }
            if !optionsEnded, argument.hasPrefix("--max-depth=") {
                bounded = Int(argument.dropFirst("--max-depth=".count)).map({ $0 >= 0 }) == true
                index += 1
                continue
            }
            if !optionsEnded, argument == "-d", arguments.indices.contains(index + 1) {
                bounded = Int(arguments[index + 1]).map({ $0 >= 0 }) == true
                index += 2
                continue
            }
            if !optionsEnded, argument.hasPrefix("-d"), argument.count > 2 {
                bounded = Int(argument.dropFirst(2)).map({ $0 >= 0 }) == true
                index += 1
                continue
            }
            if !optionsEnded, ["-e", "--regexp", "-f", "--file"].contains(argument) {
                patternFromOption = true
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded,
               argument == "-g" || argument == "--glob" ||
                argument == "-t" || argument == "--type" ||
                argument == "-T" || argument == "--type-not" ||
                argument == "--iglob" {
                hasGlobFilter = true
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded, argument.hasPrefix("--"),
               let option = argument.split(separator: "=", maxSplits: 1).first,
               ["--glob", "--type", "--type-not", "--iglob", "--after-context",
                "--before-context", "--context", "--max-count", "--threads", "--engine",
                "--encoding", "--sort", "--sortr"].contains(String(option)),
               !argument.contains("=") {
                hasGlobFilter = true
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded, ["-g", "-t", "-T", "-A", "-B", "-C", "-m"].contains(argument) {
                if ["-g", "-t", "-T"].contains(argument) { hasGlobFilter = true }
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded,
               argument.hasPrefix("--glob=") || argument.hasPrefix("--type=") ||
                argument.hasPrefix("--type-not=") || argument.hasPrefix("--iglob=") ||
                argument.hasPrefix("-g") || argument.hasPrefix("-t") || argument.hasPrefix("-T") {
                hasGlobFilter = true
                index += 1
                continue
            }
            if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                index += 1
                continue
            }
            positionals.append(argument)
            index += 1
        }

        let paths: [String]
        if filesMode || patternFromOption {
            paths = positionals
        } else if positionals.isEmpty {
            return nil
        } else {
            paths = Array(positionals.dropFirst())
        }
        if readsFromPipeline, !filesMode, paths.isEmpty {
            return nil
        }
        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        let hasFilter = filesMode ? hasGlobFilter : (patternFromOption || !positionals.isEmpty)
        return Scan(
            tool: "rg",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: bounded,
            hasSelectionFilter: hasFilter
        )
    }

    private static func grepScan(_ arguments: [String], readsFromPipeline: Bool) -> Scan? {
        var recursive = false
        var patternFromOption = false
        var hasIncludeFilter = false
        var hasPruneFilter = false
        var positionals: [String] = []
        var index = 0
        var optionsEnded = false
        let optionsWithValues: Set<String> = [
            "-e", "--regexp", "-f", "--file", "-m", "--max-count", "-A", "-B", "-C",
            "--include", "--exclude", "--exclude-dir", "--exclude-from", "--color",
            "--binary-files", "-D", "-d", "--directories", "--label",
        ]

        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, optionsWithValues.contains(argument) {
                if argument == "-e" || argument == "--regexp" ||
                    argument == "-f" || argument == "--file" {
                    patternFromOption = true
                }
                if argument == "--include" { hasIncludeFilter = true }
                if argument == "--exclude-dir" { hasPruneFilter = true }
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded, argument.hasPrefix("-"), argument.count > 1 {
                if argument == "--recursive" || argument == "--dereference-recursive" ||
                    argument == "-r" || argument == "-R" {
                    recursive = true
                } else if argument.hasPrefix("--") {
                    if let option = argument.split(separator: "=", maxSplits: 1).first,
                       ["--include", "--exclude", "--exclude-dir", "--exclude-from",
                        "--max-count", "--regexp", "--file"].contains(String(option)),
                       !argument.contains("=") {
                        if option == "--include" { hasIncludeFilter = true }
                        if option == "--exclude-dir" { hasPruneFilter = true }
                        index += min(2, arguments.count - index)
                        continue
                    }
                    if argument.hasPrefix("--include=") { hasIncludeFilter = true }
                    if argument.hasPrefix("--exclude-dir=") { hasPruneFilter = true }
                } else if argument.dropFirst().contains("r") || argument.dropFirst().contains("R") {
                    recursive = true
                }
                index += 1
                continue
            }
            positionals.append(argument)
            index += 1
        }

        guard recursive else { return nil }
        let paths: [String]
        if patternFromOption {
            paths = positionals
        } else if positionals.isEmpty {
            paths = []
        } else {
            paths = Array(positionals.dropFirst())
        }
        if readsFromPipeline, !recursive, paths.isEmpty {
            return nil
        }
        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "grep",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: hasPruneFilter,
            hasSelectionFilter: hasIncludeFilter && (patternFromOption || !positionals.isEmpty)
        )
    }

    private static func recursiveListScan(_ arguments: [String]) -> Scan? {
        var recursive = false
        var paths: [String] = []
        var index = 0
        let optionsWithValues: Set<String> = ["-I", "-T", "-w", "--block-size", "--color", "--time-style"]

        while index < arguments.count {
            let argument = arguments[index]
            if optionsWithValues.contains(argument) {
                index += min(2, arguments.count - index)
                continue
            }
            if argument == "--recursive" {
                recursive = true
            } else if argument.hasPrefix("-"), argument != "-" {
                if argument.dropFirst().contains("R") { recursive = true }
            } else {
                paths.append(argument)
            }
            index += 1
        }

        guard recursive else { return nil }
        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "ls",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: false,
            hasSelectionFilter: false
        )
    }

    private static func treeScan(_ arguments: [String]) -> Scan? {
        var paths: [String] = []
        var bounded = false
        var hasSelectionFilter = false
        var index = 0
        let optionsWithValues: Set<String> = ["-L", "--level", "-P", "-I", "--pattern", "--ignore"]

        while index < arguments.count {
            let argument = arguments[index]
            if optionsWithValues.contains(argument), arguments.indices.contains(index + 1) {
                if argument == "-L" || argument == "--level" {
                    bounded = Int(arguments[index + 1]).map({ $0 >= 0 }) == true
                }
                if ["-P", "--pattern", "-I", "--ignore"].contains(argument) {
                    hasSelectionFilter = true
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--level=") {
                bounded = Int(argument.dropFirst("--level=".count)).map({ $0 >= 0 }) == true
            } else if argument.hasPrefix("-L"), argument.count > 2 {
                bounded = Int(argument.dropFirst(2)).map({ $0 >= 0 }) == true
            } else if argument.hasPrefix("--pattern=") || argument.hasPrefix("--ignore=") ||
                argument.hasPrefix("-P") || argument.hasPrefix("-I") {
                hasSelectionFilter = true
            } else if argument.hasPrefix("-"), argument != "-" {
                continue
            } else {
                paths.append(argument)
            }
            index += 1
        }

        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "tree",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: bounded,
            hasSelectionFilter: hasSelectionFilter
        )
    }

    private static func fdScan(_ arguments: [String]) -> Scan? {
        var positionals: [String] = []
        var bounded = false
        var index = 0
        let optionsWithValues: Set<String> = [
            "-d", "--max-depth", "-e", "--extension", "-t", "--type", "-g", "--glob",
            "-E", "--exclude", "--ignore-file", "--owner", "--changed-within",
            "--changed-before",
        ]

        while index < arguments.count {
            let argument = arguments[index]
            if optionsWithValues.contains(argument), arguments.indices.contains(index + 1) {
                if argument == "-d" || argument == "--max-depth" {
                    bounded = Int(arguments[index + 1]).map({ $0 >= 0 }) == true
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--max-depth=") {
                bounded = Int(argument.dropFirst("--max-depth=".count)).map({ $0 >= 0 }) == true
            } else if argument.hasPrefix("-d"), argument.count > 2 {
                bounded = Int(argument.dropFirst(2)).map({ $0 >= 0 }) == true
            } else if argument.hasPrefix("-"), argument != "-" {
                continue
            } else {
                positionals.append(argument)
            }
            index += 1
        }

        let paths = positionals.count > 1 ? Array(positionals.dropFirst()) : []
        let targets = effectivePaths(paths)
        guard !targets.isEmpty, targets.contains(where: { !isLikelyFilePath($0) }) else {
            return nil
        }
        return Scan(
            tool: "fd",
            paths: targets,
            hasExplicitPath: !paths.isEmpty,
            hasTraversalBoundary: bounded,
            hasSelectionFilter: !positionals.isEmpty
        )
    }

    private static func positionalArguments(
        _ arguments: [String],
        optionsWithValues: Set<String>
    ) -> [String] {
        var paths: [String] = []
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let argument = arguments[index]
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, optionsWithValues.contains(argument) {
                index += min(2, arguments.count - index)
                continue
            }
            if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                index += 1
                continue
            }
            paths.append(argument)
            index += 1
        }
        return paths
    }

    private static func effectivePaths(_ paths: [String]) -> [String] {
        paths.isEmpty ? ["."] : paths.filter { !$0.isEmpty }
    }

    private static func isLikelyFilePath(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let extensionName = (name as NSString).pathExtension.lowercased()
        let commonExtensionlessFiles: Set<String> = [
            "authors", "brewfile", "changelog", "changes", "copying", "dockerfile",
            "gnumakefile", "gemfile", "jenkinsfile", "justfile", "license", "makefile",
            "notice", "procfile", "rakefile", "readme",
        ]
        return [
            "c", "cc", "cpp", "csv", "dylib", "gif", "go", "h", "html", "jpeg", "jpg",
            "js", "json", "log", "md", "pdf", "png", "plist", "py", "rs", "sh", "sqlite",
            "swift", "tar", "txt", "xml", "yaml", "yml", "zip",
        ].contains(extensionName) || commonExtensionlessFiles.contains(name.lowercased())
    }

    private static func broadTarget(
        _ path: String,
        workingDirectory: String?
    ) -> String? {
        guard let normalized = normalizedPath(path, workingDirectory: workingDirectory) else {
            return nil
        }
        let value = normalized.lowercased()
        let broadRoots: Set<String> = [
            "/", "/system/volumes/data", "/volumes", "/mnt", "/media", "/users", "/home",
            "/root", "/proc", "/sys", "/dev", "/run",
            "/var", "/private/var", "/var/lib", "/private/var/lib", "/private/var/folders",
            "/usr", "/system", "/library", "/applications", "/opt", "/srv",
            "/var/lib/docker", "/private/var/lib/docker",
            "/var/lib/docker/overlay2", "/private/var/lib/docker/overlay2",
            "/var/lib/docker/volumes", "/private/var/lib/docker/volumes",
            "/var/lib/docker/containers", "/private/var/lib/docker/containers",
            "/var/lib/containerd", "/private/var/lib/containerd",
            "/__codex_user_home__", "/__codex_user_home__/library",
        ]
        if broadRoots.contains(value) {
            return normalized
        }

        let components = value.split(separator: "/").map(String.init)
        if components.count == 2, ["users", "home"].contains(components[0]) {
            return normalized
        }
        if components.count == 2, ["volumes", "mnt", "media"].contains(components[0]) {
            return normalized
        }
        if components.count == 3,
           ["users", "home"].contains(components[0]),
           components[2] == "library" {
            return normalized
        }
        return nil
    }

    private static func isDockerStorageTree(_ path: String) -> Bool {
        let value = path.lowercased()
        return value == "/var/lib/docker" ||
            value.hasPrefix("/var/lib/docker/overlay2") ||
            value == "/private/var/lib/docker" ||
            value.hasPrefix("/private/var/lib/docker/overlay2")
    }

    private static func normalizedPath(
        _ path: String,
        workingDirectory: String?
    ) -> String? {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        value = value.replacingOccurrences(of: "${HOME}", with: "/__codex_user_home__")
            .replacingOccurrences(of: "$HOME", with: "/__codex_user_home__")
        if value == "~" {
            value = "/__codex_user_home__"
        } else if value.hasPrefix("~/") {
            value = "/__codex_user_home__/" + value.dropFirst(2)
        }

        if let wildcard = value.firstIndex(where: { ["*", "?", "["].contains($0) }) {
            let prefix = String(value[..<wildcard])
            value = prefix.hasSuffix("/") ? String(prefix.dropLast()) : (prefix as NSString).deletingLastPathComponent
            if value.isEmpty { value = "/" }
        }

        guard !value.hasPrefix("~"), !value.contains("$") else { return nil }
        if !value.hasPrefix("/") {
            guard let workingDirectory,
                  !workingDirectory.isEmpty,
                  workingDirectory.hasPrefix("/") else {
                return nil
            }
            value = (workingDirectory as NSString).appendingPathComponent(value)
        }

        var components: [String] = []
        for component in value.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        if components.prefix(3).map({ $0.lowercased() }) == ["system", "volumes", "data"] {
            let remainder = components.dropFirst(3)
            return remainder.isEmpty ? "/" : "/" + remainder.joined(separator: "/")
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func commandSegments(_ command: String) -> [CommandSegment] {
        var segments: [CommandSegment] = []
        var words: [String] = []
        var word = ""
        var wordStarted = false
        var quote: Character?
        var escaped = false
        var readsFromPipeline = false
        let characters = Array(command)
        var index = 0

        func finishWord() {
            guard wordStarted else { return }
            words.append(word)
            word = ""
            wordStarted = false
        }

        func finishSegment() {
            finishWord()
            guard !words.isEmpty else { return }
            segments.append(CommandSegment(words: words, readsFromPipeline: readsFromPipeline))
            words = []
            readsFromPipeline = false
        }

        while index < characters.count {
            let character = characters[index]
            if escaped {
                word.append(character)
                wordStarted = true
                escaped = false
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == "\\", activeQuote == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
                wordStarted = true
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                wordStarted = true
            } else if character == "\\" {
                escaped = true
                wordStarted = true
            } else if character.isWhitespace {
                if character.isNewline {
                    finishSegment()
                } else {
                    finishWord()
                }
            } else if character == "|" {
                finishSegment()
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    index += 1
                } else {
                    readsFromPipeline = true
                    if index + 1 < characters.count, characters[index + 1] == "&" {
                        index += 1
                    }
                }
            } else if [";", "&", "(", ")"].contains(character) {
                finishSegment()
            } else {
                word.append(character)
                wordStarted = true
            }
            index += 1
        }
        finishSegment()
        return segments
    }

    private static func commandSubstitutions(in command: String) -> [String] {
        let characters = Array(command)
        var substitutions: [String] = []
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == "\\" && activeQuote == "\"" {
                    escaped = true
                    index += 1
                    continue
                }
                if character == activeQuote {
                    quote = nil
                    index += 1
                    continue
                }
                if activeQuote == "\"", character == "$",
                   characters.indices.contains(index + 1), characters[index + 1] == "(",
                   let substitution = commandSubstitution(in: characters, openingIndex: index + 1) {
                    substitutions.append(substitution.body)
                    index = substitution.endIndex + 1
                    continue
                }
                if activeQuote == "\"", character == "`",
                   let substitution = backtickSubstitution(in: characters, openingIndex: index) {
                    substitutions.append(substitution.body)
                    index = substitution.endIndex + 1
                    continue
                }
                index += 1
                continue
            }
            if character == "\\" {
                escaped = true
                index += 1
            } else if character == "'" || character == "\"" {
                quote = character
                index += 1
            } else if character == "$",
                      characters.indices.contains(index + 1), characters[index + 1] == "(",
                      let substitution = commandSubstitution(in: characters, openingIndex: index + 1) {
                substitutions.append(substitution.body)
                index = substitution.endIndex + 1
            } else if character == "`",
                      let substitution = backtickSubstitution(in: characters, openingIndex: index) {
                substitutions.append(substitution.body)
                index = substitution.endIndex + 1
            } else {
                index += 1
            }
        }
        return substitutions
    }

    private static func commandSubstitution(
        in characters: [Character],
        openingIndex: Int
    ) -> (body: String, endIndex: Int)? {
        var depth = 1
        var quote: Character?
        var escaped = false
        var index = openingIndex + 1

        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if let activeQuote = quote {
                if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "$",
                          characters.indices.contains(index + 1), characters[index + 1] == "(" {
                    depth += 1
                    index += 1
                }
                index += 1
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "$",
                      characters.indices.contains(index + 1), characters[index + 1] == "(" {
                depth += 1
                index += 1
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return (String(characters[(openingIndex + 1)..<index]), index)
                }
            }
            index += 1
        }
        return nil
    }

    private static func backtickSubstitution(
        in characters: [Character],
        openingIndex: Int
    ) -> (body: String, endIndex: Int)? {
        var escaped = false
        var index = openingIndex + 1
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\" {
                escaped = true
                index += 1
                continue
            }
            if character == "`" {
                return (String(characters[(openingIndex + 1)..<index]), index)
            }
            index += 1
        }
        return nil
    }

    private static func isAbsoluteOrHomePath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("$HOME") || path.hasPrefix("${HOME}")
    }

    private static func isCommandWrapper(_ command: String) -> Bool {
        [
            "ssh", "sudo", "doas", "timeout", "sh", "bash", "zsh", "dash", "ksh", "fish",
            "env", "xargs", "command", "exec", "nohup", "time", "nice", "ionice", "stdbuf",
            "setsid", "sshpass",
        ].contains(command)
    }

    private static func unresolvedScan(tool: String) -> Scan {
        Scan(
            tool: tool,
            paths: ["$UNRESOLVED_SCAN_SCOPE"],
            hasExplicitPath: false,
            hasTraversalBoundary: false,
            hasSelectionFilter: false
        )
    }

    private static func removingRedirections(_ words: [String]) -> [String] {
        var result: [String] = []
        var skipTarget = false
        for word in words {
            if skipTarget {
                skipTarget = false
                continue
            }
            if let range = word.range(of: #"^\d*(?:>>?|<<?)"#, options: .regularExpression) {
                skipTarget = range.upperBound == word.endIndex
                continue
            }
            result.append(word)
        }
        return result
    }

    private static func firstCommandIndex(in words: [String]) -> Int? {
        var index = 0
        let controlWords: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!"]
        while index < words.count {
            let word = words[index].lowercased()
            if controlWords.contains(word) || isAssignment(words[index]) {
                index += 1
            } else {
                return index
            }
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator != word.startIndex else {
            return false
        }
        return word[..<separator].allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
    }

    private static func basename(_ command: String) -> String {
        command.split(separator: "/").last.map(String.init) ?? command
    }

    private static func wrapperCommandIndex(
        in arguments: [String],
        optionsWithValues: Set<String>
    ) -> Int {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return index + 1
            }
            if !argument.hasPrefix("-") || argument == "-" {
                return index
            }
            let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if optionsWithValues.contains(optionName), !argument.contains("=") {
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private static func timeoutCommand(_ arguments: [String]) -> [String] {
        let optionValues: Set<String> = ["-k", "--kill-after", "-s", "--signal"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if optionValues.contains(optionName), !argument.contains("=") {
                index += 2
            } else {
                index += 1
            }
        }
        if index < arguments.count { index += 1 }
        return Array(arguments.dropFirst(min(index, arguments.count)))
    }

    private static func shellCommand(_ arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            let isCommandOption = argument == "-c" ||
                argument == "--command" ||
                argument.hasPrefix("--command=") ||
                (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains("c"))
            guard isCommandOption else { continue }
            if argument.hasPrefix("--command=") {
                return String(argument.dropFirst("--command=".count))
            }
            guard arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        return nil
    }

    private static func sshCommandArguments(_ arguments: [String]) -> [String] {
        let optionsWithValues: Set<String> = [
            "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
            "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
            "--bind-interface", "--bind-address", "--config", "--identity-file",
            "--jump", "--login-name", "--port",
        ]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-") else { break }
            let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if optionsWithValues.contains(optionName), !argument.contains("=") {
                index += 2
            } else {
                index += 1
            }
        }
        guard index < arguments.count else { return [] }
        return Array(arguments.dropFirst(index + 1))
    }
}
