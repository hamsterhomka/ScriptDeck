import AppKit
import Observation

enum RunState: Equatable {
    case idle
    case running
    case stopping
    case exited(Int32)
    case stopped
    case failed(String)

    var isActive: Bool { self == .running || self == .stopping }
}

/// Режет байтовый поток на строки, корректно обрабатывая разорванный UTF-8 и `\r`.
/// Используется только из очереди readabilityHandler.
private final class LineSplitter {
    private var remainder = Data()

    func feed(_ data: Data) -> [String] {
        remainder.append(data)
        var lines: [String] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder[remainder.startIndex..<newline]
            lines.append(Self.normalize(lineData))
            remainder = Data(remainder[remainder.index(after: newline)...])
        }
        return lines
    }

    func flush() -> [String] {
        defer { remainder = Data() }
        return remainder.isEmpty ? [] : [Self.normalize(remainder)]
    }

    /// Прогресс-бары перерисовывают строку через `\r` — оставляем только последнее состояние.
    private static func normalize(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        while line.hasSuffix("\r") { line.removeLast() }
        if let lastCR = line.lastIndex(of: "\r") {
            line = String(line[line.index(after: lastCR)...])
        }
        return line
    }
}

@MainActor
@Observable
final class RunSession: Identifiable {
    let key: ScriptKey
    let displayCommand: String

    private(set) var state: RunState = .idle
    private(set) var lines: [NSAttributedString] = []
    /// Меняется, когда лог нужно перерисовать целиком (очистка, обрезка).
    private(set) var rebuildToken = 0
    private(set) var detectedURL: URL?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var hasUnseenError = false

    nonisolated var id: ScriptKey { key }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let renderer = ANSIRenderer()

    private static let maxLines = 12_000
    private static let trimmedLines = 9_000
    private static let localURLRegex = try! NSRegularExpression(
        pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(:\d+)?[^\s]*"#)

    var onStateChange: ((RunSession) -> Void)?

    init(key: ScriptKey, displayCommand: String) {
        self.key = key
        self.displayCommand = displayCommand
    }

    // MARK: - Управление

    func start(command: String, directory: URL) {
        guard !state.isActive else { return }
        detectedURL = nil
        hasUnseenError = false
        finishedAt = nil
        renderer.reset()

        if !lines.isEmpty { appendSystem("") }
        appendSystem("$ \(command)", color: Palette.accent, bold: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShellEnvironment.shellPath)
        process.arguments = ["-c", "exec \(command)"]
        process.currentDirectoryURL = directory
        process.environment = ShellEnvironment.resolved()
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                let rest = splitter.flush()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendOutput(rest) } }
                return
            }
            let lines = splitter.feed(data)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendOutput(lines) } }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            // Даём дочитать последний вывод до того, как напишем "exited".
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { self?.handleExit(status: status, reason: reason) }
            }
        }

        do {
            try process.run()
            self.process = process
            startedAt = Date()
            state = .running
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            state = .failed(error.localizedDescription)
            appendSystem("Не удалось запустить: \(error.localizedDescription)", color: Palette.error)
        }
        onStateChange?(self)
    }

    func stop() {
        guard let process, state == .running else { return }
        state = .stopping
        appendSystem("■ Останавливаю…", color: Palette.dim)
        ProcessTree.terminate(process.processIdentifier)
        onStateChange?(self)
    }

    func restart(command: String, directory: URL) {
        if state.isActive {
            pendingRestart = (command, directory)
            stop()
        } else {
            start(command: command, directory: directory)
        }
    }

    @ObservationIgnored private var pendingRestart: (String, URL)?

    /// Используется при выходе из приложения.
    func killSynchronously() {
        guard let process, process.isRunning else { return }
        ProcessTree.terminateNow(process.processIdentifier)
    }

    func clear() {
        lines.removeAll()
        rebuildToken += 1
    }

    func markSeen() {
        hasUnseenError = false
    }

    var plainText: String {
        lines.map(\.string).joined(separator: "\n")
    }

    // MARK: - Вывод

    private func handleExit(status: Int32, reason: Process.TerminationReason) {
        let wasStopping = state == .stopping
        process = nil
        finishedAt = Date()

        if wasStopping {
            state = .stopped
            appendSystem("■ Остановлено", color: Palette.dim)
        } else if reason == .exit, status == 0 {
            state = .exited(0)
            appendSystem("✓ Завершено успешно", color: Palette.success, bold: true)
        } else {
            state = .exited(status)
            hasUnseenError = true
            appendSystem("✗ Завершено с кодом \(status)", color: Palette.error, bold: true)
        }
        onStateChange?(self)

        if let (command, directory) = pendingRestart {
            pendingRestart = nil
            start(command: command, directory: directory)
        }
    }

    private func appendOutput(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        for line in newLines {
            let rendered = renderer.render(line)
            lines.append(rendered.attributed)
            if detectedURL == nil { detectURL(in: rendered.plain) }
        }
        trimIfNeeded()
    }

    private func appendSystem(_ text: String, color: NSColor = Palette.dim, bold: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold ? ANSIRenderer.boldFont : ANSIRenderer.regularFont,
            .foregroundColor: color,
        ]
        lines.append(NSAttributedString(string: text, attributes: attributes))
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard lines.count > Self.maxLines else { return }
        lines.removeFirst(lines.count - Self.trimmedLines)
        rebuildToken += 1
    }

    private func detectURL(in text: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.localURLRegex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return }
        var string = String(text[swiftRange])
        while let last = string.last, ".,;:".contains(last) { string.removeLast() }
        string = string.replacingOccurrences(of: "0.0.0.0", with: "localhost")
        detectedURL = URL(string: string)
    }
}
