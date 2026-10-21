import Foundation

enum PackageManager: String, Codable, CaseIterable {
    case npm, yarn, pnpm, bun

    static func detect(in directory: URL) -> PackageManager {
        let fileManager = FileManager.default
        let has: (String) -> Bool = { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        if has("bun.lockb") || has("bun.lock") { return .bun }
        if has("pnpm-lock.yaml") { return .pnpm }
        if has("yarn.lock") { return .yarn }
        return .npm
    }

    func runCommand(for script: String) -> String {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(rawValue) run \(quoted)"
    }
}

struct Script: Hashable, Identifiable {
    let name: String
    let command: String
    var id: String { name }
}

struct Project: Identifiable, Hashable {
    let path: String
    var name: String
    /// Имя для UI: путь относительно папки вкладки (или имя из package.json).
    var title: String
    var scripts: [Script]
    var packageManager: PackageManager
    var loadError: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    static func load(path: String, title: String? = nil) -> Project {
        let directory = URL(fileURLWithPath: path)
        let fallbackName = directory.lastPathComponent
        let manager = PackageManager.detect(in: directory)
        let packageURL = directory.appendingPathComponent("package.json")

        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Project(path: path, name: fallbackName, title: title ?? fallbackName, scripts: [], packageManager: manager,
                           loadError: "Не удалось прочитать package.json")
        }

        let name = (json["name"] as? String) ?? fallbackName
        let scriptsDict = (json["scripts"] as? [String: String]) ?? [:]
        let raw = String(decoding: data, as: UTF8.self)
        let scripts = orderedScripts(scriptsDict, raw: raw)
        return Project(path: path, name: name, title: title ?? name, scripts: scripts, packageManager: manager, loadError: nil)
    }

    /// JSONSerialization теряет порядок ключей — восстанавливаем его по позиции в исходном файле.
    private static func orderedScripts(_ dict: [String: String], raw: String) -> [Script] {
        let scriptsStart = raw.range(of: "\"scripts\"")?.upperBound ?? raw.startIndex
        let tail = raw[scriptsStart...]
        func position(_ key: String) -> Int {
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            guard let range = tail.range(of: "\"\(escaped)\"") else { return Int.max }
            return tail.distance(from: tail.startIndex, to: range.lowerBound)
        }
        let positions: [String: Int] = dict.keys.reduce(into: [:]) { result, key in result[key] = position(key) }
        let sortedKeys = dict.keys.sorted { lhs, rhs in
            let left = positions[lhs] ?? Int.max
            let right = positions[rhs] ?? Int.max
            return left == right ? lhs < rhs : left < right
        }
        return sortedKeys.map { Script(name: $0, command: dict[$0] ?? "") }
    }
}

struct ScriptKey: Hashable, Codable {
    let projectPath: String
    let scriptName: String
}
