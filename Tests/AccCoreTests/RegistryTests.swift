import Foundation
import Testing
@testable import AccCore

let sample = Registry(current: [.claude: "cto", .codex: "work"], accounts: [
    Account(id: "team", tool: .claude, label: "Haz (team)", configDir: nil, email: "hazli@cynco.io"),
    Account(id: "work", tool: .codex, label: "Work", configDir: nil, email: "w@cynco.io"),
    Account(id: "personal", tool: .claude, label: "Haz (Personal)", configDir: "~/.claude-acc2", email: "hazli@cynco.io"),
    Account(id: "cto", tool: .claude, label: "CTO", configDir: "~/.claude-acc4", email: "cto@cynco.io"),
    Account(id: "side", tool: .codex, label: "Side", configDir: "/abs/side"),
])

func tempStore() -> RegistryStore {
    RegistryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("acc-tests-\(UUID().uuidString)"))
}

func tempHome() -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("acc-home-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return canonical(path)
}

@Suite struct Resolve {
    @Test func orderedGroupsByToolKeepingUserOrder() {
        #expect(sample.ordered.map(\.id) == ["team", "personal", "cto", "work", "side"])
    }

    @Test func positionsFollowDisplayOrder() throws {
        #expect(try sample.resolve("3").id == "cto")
        #expect(try sample.resolve("4").id == "work")
        #expect(try sample.resolve("5", tool: .codex).id == "side")
        #expect(throws: AccError.noMatch("2")) { try sample.resolve("2", tool: .codex) }
    }

    @Test func byIDLabelFragmentEmail() throws {
        #expect(try sample.resolve("side").id == "side")
        #expect(try sample.resolve("haz (personal)").id == "personal")
        #expect(try sample.resolve("pers").id == "personal")
        #expect(try sample.resolve("cto@").id == "cto")
    }

    @Test func toolScopeNarrowsAmbiguity() throws {
        #expect(throws: AccError.ambiguous("c", ["team", "personal", "cto", "work"])) { try sample.resolve("c") }
        #expect(try sample.resolve("c", tool: .codex).id == "work")
    }

    @Test func unknownAndOutOfRange() {
        #expect(throws: AccError.noMatch("nope")) { try sample.resolve("nope") }
        #expect(throws: AccError.noMatch("9")) { try sample.resolve("9") }
        #expect(throws: AccError.noMatch("0")) { try sample.resolve("0") }
    }

    @Test func accountFromVariable() {
        #expect(sample.account(for: .claude, configDir: nil)?.id == "team")
        #expect(sample.account(for: .codex, configDir: "")?.id == "work")
        #expect(sample.account(for: .codex, configDir: "/abs/side/")?.id == "side")
        #expect(sample.account(for: .claude, configDir: "/abs/side") == nil)
    }

    @Test func folders() {
        #expect(sample.account(id: "team")!.folder(home: "/h") == "/h/.claude")
        #expect(sample.account(id: "work")!.folder(home: "/h") == "/h/.codex")
        #expect(sample.account(id: "cto")!.folder(home: "/h") == "/h/.claude-acc4")
        #expect(Account(id: "o", tool: .opencode, label: "o", configDir: nil).folder(home: "/h") == "/h/.local/share")
    }
}

@Suite struct Validate {
    func problems(_ change: (inout Registry) -> Void) -> [String] {
        var r = sample
        change(&r)
        do { try r.validate(); return [] } catch AccError.invalidRegistry(let p) { return p } catch { return ["\(error)"] }
    }

    @Test func sampleIsValid() throws { try sample.validate() }
    @Test func emptyIsValid() throws { try Registry.empty.validate() }
    @Test func duplicateID() { #expect(problems { $0.accounts[2].id = "team" } == ["duplicate id 'team'"]) }
    @Test func reservedIDs() {
        #expect(problems { $0.accounts[4].id = "codex" } == ["id 'codex' is reserved for an acc command"])
        #expect(problems { $0.accounts[4].id = "launch" } == ["id 'launch' is reserved for an acc command"])
    }
    @Test func oneDefaultFolderPerTool() {
        #expect(problems { $0.accounts[2].configDir = nil } == ["more than one Claude Code account uses the default folder (configDir: null)"])
    }
    @Test func currentMustBeOfItsTool() {
        #expect(problems { $0.current[.codex] = "cto" } == ["current Codex account 'cto' is not a Codex account in the list"])
        #expect(problems { $0.current[.claude] = nil } == ["no current Claude Code account"])
    }
    @Test func futureVersionIsRejected() {
        var r = sample
        r.version = 3
        #expect(throws: AccError.unsupportedVersion(3)) { try r.validate() }
    }
}

@Suite struct Store {
    @Test func roundTripKeepsToolKeyedCurrent() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(try store.load() == sample)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains(#""codex" : "work""#))
    }

    @Test func missingFile() {
        let store = tempStore()
        #expect(throws: AccError.registryMissing(path: store.file.path)) { try store.load() }
    }

    @Test func invalidWriteLeavesFileUntouched() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(throws: (any Error).self) { try store.update { $0.current[.codex] = "cto" } }
        #expect(try store.load() == sample)
    }

    @Test func malformedJSONNamesTheProblem() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"current":{},"accounts":[{"id":"a","tool":"claude"}]}"#.utf8).write(to: store.file)
        #expect {
            try store.load()
        } throws: { error in
            guard case AccError.registryUnreadable(_, let reason) = error else { return false }
            return reason == "missing field 'label' at .accounts[0]"
        }
    }
}

@Suite struct Editing {
    @Test func firstAccountOfAToolBecomesCurrent() throws {
        var r = sample
        try r.add(Account(id: "oc", tool: .opencode, label: "OC", configDir: nil))
        #expect(r.current[.opencode] == "oc")
        try r.add(Account(id: "oc2", tool: .opencode, label: "OC2", configDir: "~/.opencode-oc2"))
        #expect(r.current[.opencode] == "oc")
    }

    @Test func failedAddChangesNothing() {
        var r = sample
        #expect(throws: (any Error).self) { try r.add(Account(id: "two", tool: .claude, label: "Two", configDir: nil)) }
        #expect(throws: AccError.duplicateID("cto")) { try r.add(Account(id: "cto", tool: .codex, label: "x", configDir: "~/x")) }
        #expect(throws: AccError.invalidID("opencode")) { try r.add(Account(id: "opencode", tool: .codex, label: "x", configDir: "~/x")) }
        #expect(r == sample)
    }

    @Test func useSwitchesOnlyThatTool() throws {
        var r = sample
        try r.use("side")
        #expect(r.current == [.claude: "cto", .codex: "side"])
    }

    @Test func removeGuardsCurrentAndPrimaryWhileOthersRemain() throws {
        var r = sample
        #expect(throws: (any Error).self) { try r.remove("cto") }
        #expect(throws: (any Error).self) { try r.remove("team") }
        try r.remove("personal")
        try r.use("work")
        try r.remove("side")
        try r.remove("work")
        #expect(r.current[.codex] == nil)
        #expect(r.accounts.map(\.id) == ["team", "cto"])
        try r.validate()
    }

    @Test func moveWithinTool() {
        var r = sample
        r.move("cto", toToolIndex: 0)
        #expect(r.ordered.map(\.id) == ["cto", "team", "personal", "work", "side"])
        r.move("cto", toToolIndex: 99)
        #expect(r.ordered.map(\.id) == ["team", "personal", "cto", "work", "side"])
        r.move("side", toToolIndex: 0)
        #expect(r.ordered.map(\.id) == ["team", "personal", "cto", "side", "work"])
    }

    @Test func suggestedIDsAndNewAccountFolders() {
        #expect(sample.suggestedID(for: "Hello Team!") == "hello-team")
        #expect(sample.suggestedID(for: "CTO") == "cto-2")
        #expect(sample.suggestedID(for: "Codex") == "codex-2")
        #expect(sample.suggestedID(for: "42") == "acc-42")
        #expect(sample.newAccount(tool: .codex, label: "Client A").configDir == "~/.codex-client-a")
        #expect(sample.newAccount(tool: .opencode, label: "Mine").configDir == "~/.opencode-mine")
    }
}

@Suite struct Removing {
    @Test func removedFoldersStayKnownUntilAddedBack() throws {
        var r = sample
        try r.remove("side")
        #expect(r.knows(.codex, configDir: "/abs/side/", home: "/h"))
        #expect(!r.knows(.codex, configDir: "/abs/other", home: "/h"))
        try r.add(Account(id: "side", tool: .codex, label: "Side", configDir: "/abs/side"))
        #expect(r.removed.isEmpty)
    }

    @Test func registriesFromBeforeRemovedStillLoad() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"version":2,"current":{"claude":"t"},"accounts":[{"id":"t","tool":"claude","label":"T"}]}"#.utf8).write(to: store.file)
        #expect(try store.load().removed == [])
    }

    @Test func adoptTakesTheCachedEmail() throws {
        let home = tempHome()
        write(#"{"oauthAccount":{"emailAddress":"w@cynco.io"}}"#, to: home + "/.claude-work/.claude.json")
        var r = Registry.empty
        let a = try r.adopt(Discovery.Candidate(tool: .claude, label: "work", configDir: "~/.claude-work"), home: home)
        #expect(a.id == "work" && a.email == "w@cynco.io" && r.current[.claude] == "work")
    }
}
