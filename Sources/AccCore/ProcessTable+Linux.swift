#if os(Linux)
import Foundation
import Glibc

/// The process table through /proc.
enum ProcessTable {
    /// Calls `body` with each of this user's processes: its pid, parent and name (the kernel's
    /// `comm`, at most 15 bytes).
    static func forEachUserProcess(_ body: (pid_t, pid_t, UnsafeRawBufferPointer) -> Void) {
        guard let proc = opendir("/proc") else { return }
        defer { closedir(proc) }
        let uid = getuid()
        var buffer = [UInt8](repeating: 0, count: 512)
        while let entry = readdir(proc) {
            let pid = withUnsafeBytes(of: entry.pointee.d_name) { pid_t(String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)) }
            var owner = stat()
            guard let pid, pid > 0, stat("/proc/\(pid)", &owner) == 0, owner.st_uid == uid,
                  let (parent, name) = statLine(pid, into: &buffer)
            else { continue }
            buffer.withUnsafeBytes { body(pid, parent, UnsafeRawBufferPointer(rebasing: $0[name])) }
        }
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 512)
        return statLine(pid, into: &buffer)?.parent
    }

    static func executablePath(_ pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX)) { buffer in
            let length = readlink("/proc/\(pid)/exe", buffer.baseAddress!, buffer.count)
            return length > 0 ? String(decoding: UnsafeRawBufferPointer(buffer).prefix(length), as: UTF8.self) : nil
        }
    }

    /// The parent and where the name is in /proc/<pid>/stat: `pid (name) state ppid …`. A name can
    /// hold spaces and parentheses, so it runs to the last `)`.
    private static func statLine(_ pid: pid_t, into buffer: inout [UInt8]) -> (parent: pid_t, name: Range<Int>)? {
        guard let count = readFile("/proc/\(pid)/stat", into: &buffer) else { return nil }
        let line = buffer[..<count]
        guard let open = line.firstIndex(of: UInt8(ascii: "(")), let close = line.lastIndex(of: UInt8(ascii: ")")), open < close
        else { return nil }
        let fields = line[(close + 1)...].split(separator: UInt8(ascii: " "))
        guard fields.count > 1, let parent = pid_t(String(decoding: fields[1], as: UTF8.self)) else { return nil }
        return (parent, (open + 1)..<close)
    }

    /// Reads a whole /proc file into `buffer`, growing it as needed, and returns the length. The kernel
    /// reports these files' size as 0, so they're read to the end rather than by size.
    static func readFile(_ path: String, into buffer: inout [UInt8]) -> Int? {
        let file = open(path, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var count = 0
        while true {
            if count == buffer.count { buffer += [UInt8](repeating: 0, count: buffer.count) }
            let read = buffer.withUnsafeMutableBytes { Glibc.read(file, $0.baseAddress! + count, $0.count - count) }
            if read == 0 { return count }
            if read < 0 {
                if errno == EINTR { continue }
                return nil
            }
            count += read
        }
    }

    /// The desktop app whose systemd unit the session runs in, which it inherits from the terminal
    /// or editor that started it.
    static func launcher(of pid: pid_t, parents: [pid_t]) -> Launcher {
        var buffer = [UInt8](repeating: 0, count: 1024)
        guard let count = readFile("/proc/\(pid)/cgroup", into: &buffer),
              let id = RunningSessions.appID(fromCgroup: String(decoding: buffer[..<count], as: UTF8.self))
        else { return .background }
        return Launcher(name: appNames.name(of: id), bundle: id)
    }

    /// The `Name` of the app's desktop entry, else its ID.
    private static let appNames = RunningSessions.AppNames { id in
        RunningSessions.knownApps.first { id.hasPrefix($0.idPrefix) }?.name
            ?? desktopEntryFolders().lazy
                .compactMap { try? String(contentsOfFile: "\($0)/\(id).desktop", encoding: .utf8) }
                .compactMap(RunningSessions.desktopEntryName).first
            ?? id
    }

    /// Where desktop entries live, most specific first, per the XDG base directory spec.
    private static func desktopEntryFolders() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? userHome() + "/.local/share"
        let dataDirs = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
        return ([dataHome] + dataDirs.split(separator: ":").map(String.init)).map { $0 + "/applications" }
    }

    /// Two buffers, for arguments and environment, reused across a scan.
    struct ArgumentReader {
        private var arguments = [UInt8](repeating: 0, count: 4 * 1024)
        private var environment = [UInt8](repeating: 0, count: 32 * 1024)

        mutating func facts(of pid: pid_t, variables: [String], flags: [String]) -> RunningSessions.Facts? {
            guard let argumentCount = ProcessTable.readFile("/proc/\(pid)/cmdline", into: &arguments),
                  let environmentCount = ProcessTable.readFile("/proc/\(pid)/environ", into: &environment)
            else { return nil }
            return arguments.withUnsafeBytes { arguments in
                environment.withUnsafeBytes { environment in
                    RunningSessions.facts(cmdline: UnsafeRawBufferPointer(rebasing: arguments.prefix(argumentCount)),
                                          environ: UnsafeRawBufferPointer(rebasing: environment.prefix(environmentCount)),
                                          variables: variables, flags: flags)
                }
            }
        }
    }
}
#endif
