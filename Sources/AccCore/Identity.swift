import Foundation

/// Who an account is logged in as, from the files its tool keeps: no tool run, no network.
public struct Identity: Equatable, Sendable {
    public let email: String?
    /// "Team", "Max", "Plus".
    public let plan: String?
    /// The Claude login, as a user id and an organization id. One person in two organizations has
    /// one user id, so a session that names its login (Claude desktop's do) needs both to find its account.
    public let login: Login?

    public struct Login: Hashable, Sendable {
        public let account: String
        public let organization: String?

        public init(account: String, organization: String?) {
            self.account = account
            self.organization = organization
        }
    }

    public init(email: String?, plan: String?, login: Login? = nil) {
        self.email = email
        self.plan = plan
        self.login = login
    }

    public static func read(_ account: Account, home: String = userHome()) -> Identity? {
        switch account.tool {
        case .claude: ClaudeSupport.identity(account, home: home)
        case .codex: CodexSupport.identity(home: account.folder(home: home))
        case .opencode: nil
        }
    }
}
