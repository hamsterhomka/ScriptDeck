import Darwin
import Foundation

/// yarn → node → esbuild и т.д.: убить только корневой процесс недостаточно, гасим всё дерево.
enum ProcessTree {
    static func descendants(of root: pid_t) -> [pid_t] {
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for (pid, parent) in allProcesses() {
            childrenByParent[parent, default: []].append(pid)
        }
        var result: [pid_t] = []
        var queue = [root]
        while let current = queue.popLast() {
            for child in childrenByParent[current] ?? [] where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    static func terminate(_ root: pid_t, graceSeconds: Double = 2.5) {
        let tree = [root] + descendants(of: root)
        for pid in tree.reversed() { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + graceSeconds) {
            for pid in tree where isAlive(pid) { kill(pid, SIGKILL) }
        }
    }

    /// Синхронный вариант для выхода из приложения.
    static func terminateNow(_ root: pid_t) {
        let tree = [root] + descendants(of: root)
        for pid in tree.reversed() { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, tree.contains(where: isAlive) { usleep(50_000) }
        for pid in tree where isAlive(pid) { kill(pid, SIGKILL) }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private static func allProcesses() -> [(pid_t, pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(actual).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }
}
