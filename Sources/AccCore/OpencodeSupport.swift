import Foundation

/// opencode specifics. An account is an XDG_DATA_HOME holding opencode/opencode.db
/// (credentials and sessions); acc launches non-default accounts with --standalone so they
/// get a private server instead of the shared one that runs as the default account.
public enum OpencodeSupport {
    static func authStatus(_ runner: Runner, _ account: Account) throws -> Runner.AuthStatus {
        struct Connection: Decodable { let label: String? }
        struct Provider: Decodable { let id: String; let name: String?; let connections: [Connection]? }
        let (code, output) = try runner.capture(["auth", "list", "--format", "json"], account: account, includeErrors: false)
        guard let providers = try? JSONDecoder().decode([Provider].self, from: output) else {
            throw AccError.toolFailed("opencode", "`opencode auth list` exited \(code) without readable output")
        }
        let connected = providers.filter { !($0.connections ?? []).isEmpty }.map { $0.name ?? $0.id }
        return Runner.AuthStatus(loggedIn: !connected.isEmpty, email: nil,
                                 detail: connected.isEmpty ? nil : connected.joined(separator: ", "))
    }
}
