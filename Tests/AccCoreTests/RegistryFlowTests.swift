import Foundation
import Testing
@testable import AccCore

@Suite struct Update {
    func fileNumber(_ store: RegistryStore) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: store.file.path)[.systemFileNumber] as? Int
    }

    @Test func aChangeThatMakesNoDifferenceIsNotWritten() throws {
        let store = tempStore()
        try store.save(sample)
        let before = try fileNumber(store)
        try store.update { try $0.use("cto") }
        #expect(try fileNumber(store) == before)
        try store.update { try $0.use("personal") }
        #expect(try fileNumber(store) != before)
        #expect(try store.load().current[.claude] == "personal")
    }

    @Test func startsFromEmptyBeforeTheFirstAccount() throws {
        let store = tempStore()
        try store.update { _ in }
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        let id = try store.update { r in
            try r.add(Account(id: "a", tool: .codex, label: "A", configDir: nil))
            return r.current[.codex]
        }
        #expect(id == "a")
        #expect(try store.load().accounts.map(\.id) == ["a"])
    }
}

@Suite struct Folders {
    @Test func typedFoldersAreKeptAbsoluteAndUnderHomeAsTilde() {
        #expect(Account.configDir(typed: ".codex-rel", cwd: "/w/p1", home: "/h") == "/w/p1/.codex-rel")
        #expect(Account.configDir(typed: "/h/.codex-side/", cwd: "/w", home: "/h") == "~/.codex-side")
        #expect(Account.configDir(typed: "~/.codex-side", cwd: "/w", home: "/h") == "~/.codex-side")
        #expect(Account.configDir(typed: "../h/./x//", cwd: "/w", home: "/h") == "~/x")
        #expect(Account.configDir(typed: "/h2/x", cwd: "/w", home: "/h") == "/h2/x")
    }

    @Test func oneFolderWrittenTwoWaysIsADuplicate() {
        var r = sample
        #expect(throws: AccError.invalidRegistry(["more than one Codex account uses /abs/side"])) {
            try r.add(Account(id: "dup", tool: .codex, label: "Dup", configDir: "/abs/side/"))
        }
        r.accounts.append(Account(id: "abs", tool: .claude, label: "Abs", configDir: "/h/.claude-acc4"))
        #expect(throws: AccError.invalidRegistry(["more than one Claude Code account uses ~/.claude-acc4"])) { try r.validate(home: "/h") }
    }
}

@Suite struct Primary {
    let firstListed = Registry(current: [.codex: "a"], accounts: [
        Account(id: "a", tool: .codex, label: "A", configDir: "~/.codex-a"),
        Account(id: "b", tool: .codex, label: "B", configDir: "~/.codex-b"),
        Account(id: "c", tool: .codex, label: "C", configDir: "~/.codex-c"),
    ])

    @Test func reorderingNeverChangesThePrimary() {
        for id in ["a", "b", "c"] {
            for index in -1...4 {
                var r = firstListed
                r.move(id, toToolIndex: index)
                #expect(r.primary(for: .codex)?.id == "a", "moving \(id) to \(index)")
            }
        }
        var r = firstListed
        r.move("c", toToolIndex: 0)
        #expect(r.accounts.map(\.id) == ["a", "c", "b"])
    }

    @Test func aPrimaryOnTheDefaultFolderLeavesTheOrderFree() {
        var r = sample
        r.move("cto", toToolIndex: 0)
        #expect(r.ordered.first?.id == "cto" && r.primary(for: .claude)?.id == "team")
    }
}

@Suite struct ShellHook {
    @Test func aliasesThatSkipAccAreFound() {
        let home = tempHome()
        write("alias claude=\"$HOME/.claude/local/claude\"\nalias codex='codex --yolo'\nalias opencode='FOO=1 opencode'\nalias ll='ls -l'\n",
              to: home + "/.zshrc")
        let found = ShellInit.bypassingAliases(.zsh, home: home)
        #expect(found.map(\.command) == ["claude"])
        #expect(found.first?.target == "$HOME/.claude/local/claude")
    }
}

@Suite struct Adding {
    @Test func addNewNamesAndPlacesTheAccount() throws {
        var r = sample
        let a = try r.addNew(.codex)
        #expect(a.label == "Codex 3" && a.id == "codex-3" && a.configDir == "~/.codex-codex-3")
        let b = try r.addNew(.codex, label: "Client", id: "cl", configDir: "/abs/client")
        #expect(r.account(id: "cl") == b && b.configDir == "/abs/client")
        #expect(throws: AccError.duplicateID("cl")) { try r.addNew(.codex, id: "cl") }
    }

    @Test func setUpCreatesTheFolderAndSharesThePrimaryConfig() throws {
        let home = tempHome()
        write("model = 1", to: home + "/.codex/config.toml")
        let runner = Runner(tool: .codex, executable: "/usr/bin/false")
        var r = Registry.empty
        let first = try r.addNew(.codex, label: "Main", configDir: home + "/.codex-main")
        #expect(try Shared.setUp(first, in: r, runner: runner, home: home) == [])
        #expect(FileManager.default.fileExists(atPath: home + "/.codex-main"))
        try r.add(Account(id: "default", tool: .codex, label: "Default", configDir: nil))
        let second = try r.addNew(.codex, label: "Side", configDir: home + "/.codex-side")
        #expect(try Shared.setUp(second, in: r, runner: runner, home: home) == ["linked config.toml"])
    }
}
