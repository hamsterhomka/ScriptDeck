import AppKit
import Darwin

/// Скрипт, запущенный где-то в системе: в WebStorm, терминале, другим пользователем и т.д.
struct ExternalScript: Identifiable, Hashable {
    let pid: pid_t
    let user: String
    let isOwn: Bool
    let startedAt: Date
    let name: String
    let command: String
    let directory: String?
    let ports: [Int]
    let usesHTTPS: Bool
    /// Откуда запущен: WebStorm, Terminal, Cursor… или nil, если родитель уже закрыт.
    let source: String?
    let isOrphan: Bool
    let tree: [pid_t]

    var id: pid_t { pid }

    func url(for port: Int) -> URL? {
        URL(string: "\(usesHTTPS ? "https" : "http")://localhost:\(port)")
    }
}

enum SystemProcesses {
    private struct RawProcess {
        let pid: pid_t
        let ppid: pid_t
        let uid: uid_t
        let comm: String
        let startedAt: Date
    }

    private struct ProcessArguments {
        let executable: String
        let args: [String]
        let env: [String: String]
    }

    private static let runtimeNames: Set<String> = ["node", "npm", "npx", "yarn", "pnpm", "bun", "deno"]
    private static let packageManagerMarkers = ["yarn.js", "/yarn", "npm-cli.js", "/npm", "npx-cli.js", "/pnpm", "pnpm.cjs", "/bun"]
    /// Служебные node-процессы IDE, агентов и глобальных утилит — это не скрипты проектов.
    private static let ignoredPathFragments = [
        ".app/Contents", "/Library/Caches/JetBrains", "/.vscode", "/.cursor", "/acp-agents/",
        "/@anthropic-ai/", "/.claude/", "/lib/node_modules/", "/.npm/_npx/",
    ]

    /// Все скрипты в системе, кроме запущенных из этого экземпляра ScriptDeck.
    static func scan() -> [ExternalScript] {
        let processes = allProcesses()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [pid_t]] = [:]
        for process in processes { children[process.ppid, default: []].append(process.pid) }

        let ownPID = getpid()
        let candidates = processes.filter { runtimeNames.contains($0.comm) }
        let candidatePIDs = Set(candidates.map(\.pid))

        func ancestors(of pid: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var current = byPID[pid]?.ppid ?? 0
            while current > 1, let process = byPID[current], !result.contains(current) {
                result.append(current)
                current = process.ppid
            }
            return result
        }

        func descendants(of pid: pid_t) -> [pid_t] {
            var result: [pid_t] = []
            var queue = [pid]
            while let current = queue.popLast() {
                for child in children[current] ?? [] where !result.contains(child) {
                    result.append(child)
                    queue.append(child)
                }
            }
            return result
        }

        let listening = listeningPorts()
        var result: [ExternalScript] = []
        var argumentsCache: [pid_t: ProcessArguments] = [:]
        // Аргументы чужих процессов sysctl не отдаёт — берём их из `ps` (без окружения).
        var psArguments: [pid_t: [String]]?
        func arguments(_ pid: pid_t) -> ProcessArguments? {
            if let cached = argumentsCache[pid] { return cached }
            var value = readArguments(pid)
            if value == nil {
                if psArguments == nil { psArguments = argumentsFromPS() }
                if let args = psArguments?[pid], !args.isEmpty {
                    value = ProcessArguments(executable: args[0], args: args, env: [:])
                }
            }
            if let value { argumentsCache[pid] = value }
            return value
        }

        for candidate in candidates {
            let chain = ancestors(of: candidate.pid)
            // Корень — верхний node-процесс в цепочке; запущенное нами пропускаем.
            guard !chain.contains(where: candidatePIDs.contains), !chain.contains(ownPID) else { continue }
            guard let rootArgs = arguments(candidate.pid) else { continue }

            let tree = [candidate.pid] + descendants(of: candidate.pid)
            let treeArgs = tree.compactMap { arguments($0) }
            let allText = treeArgs.flatMap(\.args).joined(separator: " ")
            let rootText = rootArgs.args.joined(separator: " ")
            if ignoredPathFragments.contains(where: { rootText.contains($0) }) { continue }

            let lifecycleEvent = treeArgs.lazy.compactMap { $0.env["npm_lifecycle_event"] }.first
            let isPackageManagerRun = packageManagerMarkers.contains { rootText.contains($0) } || rootArgs.args.first.map { ["npm", "yarn", "pnpm", "bun", "npx"].contains(($0 as NSString).lastPathComponent) } == true
            let binaryArgs = treeArgs.first { $0.args.contains { $0.contains("/node_modules/.bin/") } }
            let ports = tree.flatMap { listening[$0] ?? [] }
            guard lifecycleEvent != nil || isPackageManagerRun || binaryArgs != nil || !ports.isEmpty else { continue }

            let directory = workingDirectory(candidate.pid)
                ?? rootArgs.env["PWD"]
                ?? projectDirectory(fromArguments: allText)
            let command = displayCommand(binaryArgs: binaryArgs, rootArgs: rootArgs)
            let name = lifecycleEvent ?? scriptName(fromRunner: rootArgs.args) ?? command.split(separator: " ").first.map(String.init) ?? candidate.comm
            let env = treeArgs.reduce(into: [String: String]()) { $0.merge($1.env) { first, _ in first } }
            let usesHTTPS = env["VITE_HTTPS"] == "true" || env["HTTPS"] == "true" || allText.contains("--https")

            let isOrphan = candidate.ppid == 1
            let topAncestor = chain.last
            var source = topAncestor.flatMap { appName(fromPath: arguments($0)?.executable ?? "") }
            if source == nil, let bundleID = rootArgs.env["__CFBundleIdentifier"] {
                source = appName(bundleIdentifier: bundleID)
            }

            result.append(ExternalScript(
                pid: candidate.pid,
                user: userName(candidate.uid),
                isOwn: candidate.uid == getuid(),
                startedAt: candidate.startedAt,
                name: name,
                command: command,
                directory: directory,
                ports: Array(Set(ports)).sorted(),
                usesHTTPS: usesHTTPS,
                source: source,
                isOrphan: isOrphan,
                tree: tree
            ))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Разбор команд

    /// `yarn run dev`, `yarn dev`, `npm run dev`, `pnpm dev` → `dev`.
    private static func scriptName(fromRunner args: [String]) -> String? {
        guard let runnerIndex = args.firstIndex(where: { arg in
            packageManagerMarkers.contains { arg.hasSuffix($0) || arg.hasSuffix($0 + ".js") } || ["npm", "yarn", "pnpm", "bun", "npx"].contains((arg as NSString).lastPathComponent)
        }) else { return nil }
        let rest = args[(runnerIndex + 1)...].filter { !$0.hasPrefix("-") }
        guard let first = rest.first else { return nil }
        if ["run", "run-script"].contains(first) { return rest.dropFirst().first }
        if ["exec", "dlx", "x"].contains(first) { return rest.dropFirst().first }
        return first
    }

    /// `node …/node_modules/.bin/vite --port 3000` → `vite --port 3000`.
    private static func displayCommand(binaryArgs: ProcessArguments?, rootArgs: ProcessArguments) -> String {
        let args = binaryArgs?.args ?? rootArgs.args
        guard let binaryIndex = args.firstIndex(where: { $0.contains("/node_modules/.bin/") || $0.hasSuffix(".js") || $0.hasSuffix(".cjs") || $0.hasSuffix(".mjs") }) else {
            return args.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        }
        var name = (args[binaryIndex] as NSString).lastPathComponent
        for suffix in [".js", ".cjs", ".mjs"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        return ([name] + args[(binaryIndex + 1)...]).joined(separator: " ")
    }

    private static func projectDirectory(fromArguments text: String) -> String? {
        guard let range = text.range(of: "/node_modules/") else { return nil }
        let prefix = text[..<range.lowerBound]
        guard let start = prefix.lastIndex(of: " ") else { return String(prefix) }
        return String(prefix[prefix.index(after: start)...])
    }

    private static func appName(fromPath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }

    private static func appName(bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "\(uid)" }
        return String(cString: name)
    }

    // MARK: - Системные вызовы

    private static func allProcesses() -> [RawProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
            var proc = info.kp_proc
            let comm = withUnsafeBytes(of: &proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let start = proc.p_starttime
            return RawProcess(pid: proc.p_pid, ppid: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid, comm: comm,
                              startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
        }
    }

    /// argv и окружение процесса через KERN_PROCARGS2.
    private static func readArguments(_ pid: pid_t) -> ProcessArguments? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0 else { return nil }

        var size = Int(argMax)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size

        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        let executable = readString() ?? ""
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while args.count < argc, let arg = readString() { args.append(arg) }

        var env: [String: String] = [:]
        while let entry = readString(), !entry.isEmpty {
            if let equals = entry.firstIndex(of: "=") {
                env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
        }
        return ProcessArguments(executable: executable, args: args, env: env)
    }

    private static func argumentsFromPS() -> [pid_t: [String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [pid_t: [String]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, let pid = pid_t(first) else { continue }
            result[pid] = parts.dropFirst().map(String.init)
        }
        return result
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// pid → прослушиваемые TCP-порты. Сокеты чужих пользователей без root не видны.
    private static func listeningPorts() -> [pid_t: [Int]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var result: [pid_t: [Int]] = [:]
        var currentPID: pid_t?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let currentPID, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) {
                if result[currentPID]?.contains(port) != true { result[currentPID, default: []].append(port) }
            }
        }
        return result
    }
}
