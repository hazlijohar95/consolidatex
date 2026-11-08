#if canImport(Darwin)
import Darwin
import Foundation

/// The process table through libproc and sysctl. The kernel lists only this user's processes, and
/// each costs one 64-byte record.
enum ProcessTable {
    /// Calls `body` with each of this user's processes: its pid, parent and name (the kernel's
    /// `comm`, at most 16 bytes).
    static func forEachUserProcess(_ body: (pid_t, pid_t, UnsafeRawBufferPointer) -> Void) {
        let uid = UInt32(getuid())
        let size = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard size > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let listed = Int(proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))) / MemoryLayout<pid_t>.size
        for pid in pids.prefix(max(listed, 0)) where pid > 0 {
            guard let info = shortInfo(pid) else { continue }
            withUnsafeBytes(of: info.pbsi_comm) { comm in
                body(pid, pid_t(info.pbsi_ppid), UnsafeRawBufferPointer(rebasing: comm.prefix { $0 != 0 }))
            }
        }
    }

    static func parent(of pid: pid_t) -> pid_t? { shortInfo(pid).map { pid_t($0.pbsi_ppid) } }

    static func executablePath(_ pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Int(MAXPATHLEN)) { buffer in
            let length = Int(proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)))
            return length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self) : nil
        }
    }

    /// The short record, which `ps` also reads: unlike the full one, it's there for processes of
    /// other users too, such as the root-owned `login` between a terminal app and its shell.
    private static func shortInfo(_ pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// The highest app bundle among a process's parents.
    static func launcher(of pid: pid_t, parents: [pid_t]) -> Launcher {
        let highest = parents.compactMap { executablePath($0).flatMap(AppInstall.appBundle(around:)) }.last
        return highest.map { Launcher(name: appNames.name(of: $0), bundle: $0) } ?? .background
    }

    /// Read from the bundle's Info.plist alone. `Bundle(path:)` would keep each app's bundle object,
    /// and its whole parsed Info.plist, for good.
    private static let appNames = RunningSessions.AppNames { bundle in
        let info = (try? Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let id = info?["CFBundleIdentifier"] as? String
        return RunningSessions.knownApps.first { id?.hasPrefix($0.idPrefix) == true }?.name
            ?? info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
    }

    /// One buffer for every process's arguments and environment in a scan. Sessions measured 1 to 10 KB,
    /// so it starts at 32 KB. The kernel cuts the data to fit without saying so, so a buffer that comes
    /// back full is read again at the kernel's limit (`kern.argmax`, 1 MB); a larger buffer is refused.
    struct ArgumentReader {
        private var bytes = [UInt8](repeating: 0, count: 32 * 1024)

        mutating func facts(of pid: pid_t, variables: [String], flags: [String]) -> RunningSessions.Facts? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = bytes.count
            guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            if size == bytes.count, bytes.count < Self.limit {
                bytes = [UInt8](repeating: 0, count: Self.limit)
                size = bytes.count
                guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            }
            return bytes.withUnsafeBytes { RunningSessions.facts(fromProcArgs: UnsafeRawBufferPointer(rebasing: $0.prefix(size)), variables: variables, flags: flags) }
        }

        static let limit: Int = {
            var argmax: Int32 = 0
            var length = MemoryLayout<Int32>.size
            return sysctlbyname("kern.argmax", &argmax, &length, nil, 0) == 0 ? Int(argmax) : 256 * 1024
        }()
    }
}
#endif
