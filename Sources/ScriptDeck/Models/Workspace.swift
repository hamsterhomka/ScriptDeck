import Foundation

/// Вкладка: либо один проект, либо мастер-папка с несколькими проектами внутри.
struct Workspace: Identifiable, Hashable {
    let path: String
    var projects: [Project]

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    /// Мастер-папка: в корне нет своего package.json, проекты лежат внутри.
    var isGroup: Bool { projects.count != 1 || projects.first?.path != path }

    private static let maxDepth = 2
    private static let excludedNames: Set<String> = [
        "node_modules", "dist", "build", "out", "coverage", "vendor", "Pods", "ios", "android", "tmp",
    ]

    static func load(path: String) -> Workspace {
        let root = URL(fileURLWithPath: path)
        if hasPackageJSON(root) {
            return Workspace(path: path, projects: [Project.load(path: path)])
        }
        var found: [URL] = []
        collect(in: root, depth: 1, into: &found)
        let projects = found
            .map { url in Project.load(path: url.path, title: relativePath(of: url, to: root)) }
            .filter { !$0.scripts.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Workspace(path: path, projects: projects)
    }

    private static func collect(in directory: URL, depth: Int, into result: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            guard !excludedNames.contains(name), !name.hasSuffix(".worktrees") else { continue }
            let values = try? child.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            if hasPackageJSON(child) {
                // В найденный проект не спускаемся: его вложенные package.json — это уже его дело.
                result.append(child)
            } else if depth < maxDepth {
                collect(in: child, depth: depth + 1, into: &result)
            }
        }
    }

    private static func hasPackageJSON(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path)
    }

    private static func relativePath(of url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(fullPath.dropFirst(rootPath.count + 1))
    }
}
