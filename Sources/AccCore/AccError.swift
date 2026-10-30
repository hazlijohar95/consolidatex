import Foundation

public enum AccError: Error, Equatable, CustomStringConvertible {
    case registryMissing(path: String)
    case registryUnreadable(path: String, reason: String)
    case unsupportedVersion(Int)
    case invalidRegistry([String])
    case noMatch(String)
    case ambiguous(String, [String])
    case duplicateID(String)
    case invalidID(String)
    case toolNotFound(String)
    case toolFailed(String, String)
    case usage(String)
    case system(String)

    public var description: String {
        switch self {
        case .registryMissing:
            "no accounts yet (run: acc setup)"
        case .registryUnreadable(let path, let reason):
            "cannot read \(path): \(reason)"
        case .unsupportedVersion(let v):
            "registry version \(v) is not supported by this acc (expected \(Registry.currentVersion)); update acc"
        case .invalidRegistry(let problems):
            "invalid registry:\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
        case .noMatch(let ref):
            "no account matches '\(ref)' (see: acc ls)"
        case .ambiguous(let ref, let ids):
            "'\(ref)' matches \(ids.joined(separator: ", ")); be more specific"
        case .duplicateID(let id):
            "an account with id '\(id)' already exists"
        case .invalidID(let id):
            "'\(id)' is not a valid id: use lowercase letters, digits and '-', starting with a letter, and not an acc command"
        case .toolNotFound(let command):
            "\(command) is not installed (not found on PATH)"
        case .toolFailed(let command, let reason):
            "\(command) failed: \(reason)"
        case .usage(let text), .system(let text):
            text
        }
    }
}
