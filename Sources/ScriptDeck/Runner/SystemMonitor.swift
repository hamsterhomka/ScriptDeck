import Foundation
import Observation

/// Периодически сканирует систему на запущенные скрипты для домашней вкладки.
@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var scripts: [ExternalScript] = []
    private(set) var lastUpdated: Date?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var timer: Timer?

    private init() {}

    var ownCount: Int { scripts.filter(\.isOwn).count }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = SystemProcesses.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if result != self.scripts { self.scripts = result }
                    self.lastUpdated = Date()
                    self.isScanning = false
                }
            }
        }
    }

    func stop(_ script: ExternalScript) {
        if script.isOwn {
            ProcessTree.terminate(script.pid)
        } else {
            stopAsAdministrator(script)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Чужой процесс без прав не убить — просим пароль администратора системным окном macOS.
    private func stopAsAdministrator(_ script: ExternalScript) {
        let pids = script.tree.map(String.init).joined(separator: " ")
        let label = "\(script.name) (\(script.user))".filter { $0 != "\"" && $0 != "\\" }
        let source = "do shell script \"kill -TERM \(pids) 2>/dev/null; sleep 1; kill -KILL \(pids) 2>/dev/null; true\" "
            + "with administrator privileges with prompt \"ScriptDeck хочет остановить «\(label)».\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        try? process.run()
    }
}
