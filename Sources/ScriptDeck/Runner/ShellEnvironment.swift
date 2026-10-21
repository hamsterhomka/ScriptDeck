import Foundation

/// GUI-приложения не наследуют окружение из ~/.zshrc (nvm, yarn и т.д.).
/// Один раз снимаем env интерактивного login-shell и переиспользуем его для всех запусков.
enum ShellEnvironment {
    static let shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: String]?

    static func resolved() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var environment = capture() ?? fallback()
        environment["FORCE_COLOR"] = "1"
        environment["CLICOLOR_FORCE"] = "1"
        environment["TERM"] = "xterm-256color"
        environment.removeValue(forKey: "NO_COLOR")
        cached = environment
        return environment
    }

    private static func capture() -> [String: String]? {
        let marker = "__SCRIPTDECK_ENV__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-ilc", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        do { try process.run() } catch { return nil }

        let deadline = DispatchTime.now() + .seconds(8)
        let group = DispatchGroup()
        group.enter()
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        let output = String(decoding: data, as: UTF8.self)
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }

        var environment: [String: String] = [:]
        for entry in parts[1].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        // Переменные shell-сессии и того, кто запустил само приложение, скриптам не нужны.
        for key in ["SHLVL", "_", "PWD", "OLDPWD", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "XPC_SERVICE_NAME"] {
            environment.removeValue(forKey: key)
        }
        return environment["PATH"] == nil ? nil : environment
    }

    private static func fallback() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.yarn/bin", "\(home)/.volta/bin", "\(home)/.bun/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }
}
