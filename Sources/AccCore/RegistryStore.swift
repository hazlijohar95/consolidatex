import Foundation

/// Reads and writes the registry file. Every write is validated first and lands
/// with an atomic rename, so readers (the shell wrapper, the menu bar app) never
/// see a partial file.
public struct RegistryStore: Sendable {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("accounts.json") }

    public init(directory: URL) { self.directory = directory }

    /// $ACC_HOME, else ~/.config/acc.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> RegistryStore {
        if let home = environment["ACC_HOME"], !home.isEmpty {
            return RegistryStore(directory: URL(fileURLWithPath: home, isDirectory: true))
        }
        return RegistryStore(directory: URL(fileURLWithPath: userHome()).appendingPathComponent(".config/acc", isDirectory: true))
    }

    public func load() throws -> Registry {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw AccError.registryMissing(path: file.path)
        } catch {
            throw AccError.registryUnreadable(path: file.path, reason: error.localizedDescription)
        }
        let registry: Registry
        do {
            registry = try JSONDecoder().decode(Registry.self, from: data)
        } catch {
            throw AccError.registryUnreadable(path: file.path, reason: Self.describe(error))
        }
        try registry.validate()
        return registry
    }

    public func save(_ registry: Registry) throws {
        try registry.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(registry)
        data.append(0x0A)
        // It names every account's email and folder, so only its owner may read it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Stage next to the target so rename(2) stays on one volume and is atomic.
        let staging = directory.appendingPathComponent(".accounts.json.\(getpid()).tmp")
        do {
            try data.write(to: staging)
            guard rename(staging.path, file.path) == 0 else {
                throw AccError.system("cannot replace \(file.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error as? AccError ?? AccError.system("cannot write \(file.path): \(error.localizedDescription)")
        }
    }

    /// The registry, or an empty one before the first account exists.
    public func loadOrEmpty() throws -> Registry {
        do { return try load() } catch AccError.registryMissing { return .empty }
    }

    /// Applies `change` to the registry on disk, or to an empty one before the first account, and
    /// saves the result. A change that makes no difference writes nothing, so it doesn't wake
    /// whatever watches the file. Returns what `change` returns; on any error the file is untouched.
    @discardableResult
    public func update<T>(_ change: (inout Registry) throws -> T) throws -> T {
        let before = try loadOrEmpty()
        var registry = before
        let result = try change(&registry)
        if registry != before { try save(registry) }
        return result
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            "missing field '\(key.stringValue)'\(at(ctx))"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            "wrong type\(at(ctx)): \(ctx.debugDescription)"
        case DecodingError.dataCorrupted(let ctx):
            "not valid JSON\(at(ctx))"
        default:
            error.localizedDescription
        }
    }

    private static func at(_ ctx: DecodingError.Context) -> String {
        let path = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return path.isEmpty ? "" : " at \(path)"
    }
}
