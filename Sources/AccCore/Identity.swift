import Foundation

/// Who an account is logged in as, from the files its tool keeps: no tool run, no network.
public struct Identity: Equatable, Sendable {
    public let email: String?
    /// "Team", "Max", "Plus".
    public let plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }

    public static func read(_ account: Account, home: String = userHome()) -> Identity? {
        switch account.tool {
        case .claude: ClaudeSupport.identity(account, home: home)
        case .codex: CodexSupport.identity(home: account.folder(home: home))
        case .opencode: nil
        }
    }
}
