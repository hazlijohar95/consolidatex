import Foundation

/// Live usage from Codex itself: `codex app-server` speaks JSON-RPC, one object per line on stdio,
/// and `account/rateLimits/read` makes Codex ask OpenAI with its own login, so no credential passes
/// through acc. Shapes follow Codex's app-server schema (V2GetAccountRateLimitsResponse).
extension CodexSupport {
    static func liveUsage(_ runner: Runner, _ account: Account, timeout: TimeInterval = 20) -> LiveUsage.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runner.executable)
        process.arguments = runner.arguments(for: account, ["app-server"])
        process.environment = runner.environment(for: account)
        let input = Pipe(), output = Pipe()
        #if canImport(Darwin)
        // Writing to a Codex that has exited would raise SIGPIPE and end the app; the write fails instead.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            return .failed("couldn't start codex: \(String(cString: strerror(errno)))")
        }
        #endif
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let replies = Replies()
        output.fileHandleForReading.readabilityHandler = { replies.feed($0.availableData) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        do {
            try runner.prepare(account)
            try process.start()
        } catch {
            return .failed("couldn't start codex: \(error.localizedDescription)")
        }
        let deadline = Date() + timeout
        func send(_ messages: String...) -> Bool {
            let data = Data(messages.map { $0 + "\n" }.joined().utf8)
            #if canImport(Darwin)
            return (try? input.fileHandleForWriting.write(contentsOf: data)) != nil
            #else
            return withSIGPIPEBlocked { (try? input.fileHandleForWriting.write(contentsOf: data)) != nil }
            #endif
        }

        guard send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"consolidatex","title":"Consolidatex","version":"2"},"capabilities":{"experimentalApi":true}}}"#),
              replies.wait(for: 1, until: deadline) != nil
        else { return .failed("Codex didn't start its app server") }
        guard send(#"{"method":"initialized"}"#, #"{"id":2,"method":"account/rateLimits/read","params":null}"#),
              let reply = replies.wait(for: 2, until: deadline)
        else { return .failed("Codex didn't answer the usage request") }
        return outcome(ofRateLimitsReply: reply, at: Date())
    }

    static func outcome(ofRateLimitsReply line: Data, at now: Date) -> LiveUsage.Outcome {
        struct Window: Decodable { let usedPercent: Double; let resetsAt: Double?; let windowDurationMins: Int? }
        struct Snapshot: Decodable { let limitId: String?; let planType: String?; let primary: Window?; let secondary: Window? }
        struct Result: Decodable { let rateLimits: Snapshot? }
        struct Failure: Decodable { let message: String? }
        struct Reply: Decodable { let result: Result?; let error: Failure? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: line) else { return .failed("Codex sent a reply acc can't read") }
        if let error = reply.error { return .failed(error.message ?? "Codex couldn't read usage") }
        let limits = reply.result?.rateLimits
        let window = { (w: Window?) in w.map { RateWindow(usedPercent: $0.usedPercent, minutes: $0.windowDurationMins, resetsAt: $0.resetsAt) } }
        guard let limits, let usage = usage(limitID: limits.limitId, plan: limits.planType, primary: window(limits.primary),
                                            secondary: window(limits.secondary), at: now)
        else { return .failed("Codex reported no usage for this account") }
        return .reading(usage)
    }
}

/// Lines from the app server, kept by request id until someone waits for them.
private final class Replies: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var byID: [Int: Data] = [:]
    private var closed = false

    func feed(_ data: Data) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard !data.isEmpty else { closed = true; return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int {
                byID[id] = Data(line)
            }
        }
    }

    func wait(for id: Int, until deadline: Date) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while byID[id] == nil, !closed, condition.wait(until: deadline) {}
        return byID[id]
    }
}

#if !canImport(Darwin)
/// Linux has no per-descriptor F_SETNOSIGPIPE. With SIGPIPE blocked on this thread, a write to a
/// Codex that has exited fails with EPIPE and leaves the signal pending, which is taken off before
/// unblocking, so it never ends the process.
private func withSIGPIPEBlocked<Result>(_ body: () -> Result) -> Result {
    var pipe = sigset_t(), previous = sigset_t()
    sigemptyset(&pipe)
    sigaddset(&pipe, SIGPIPE)
    pthread_sigmask(SIG_BLOCK, &pipe, &previous)
    defer {
        var now = timespec()
        while sigtimedwait(&pipe, nil, &now) == SIGPIPE {}
        pthread_sigmask(SIG_SETMASK, &previous, nil)
    }
    return body()
}
#endif
