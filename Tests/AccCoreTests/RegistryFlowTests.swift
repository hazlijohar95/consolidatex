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

    @Test func aFolderCantBeAddedAgainWrittenAnotherWay() {
        var r = sample
        #expect(throws: AccError.usage("another Codex account already uses /abs/side/")) {
            try r.add(Account(id: "dup", tool: .codex, label: "Dup", configDir: "/abs/side/"))
        }
    }

    @Test func aRegistryNamingOneFolderTwoWaysStillLoads() throws {
        var r = sample
        r.accounts.append(Account(id: "abs", tool: .codex, label: "Abs", configDir: "/abs/side/"))
        try r.validate()
    }

    @Test func discoveryListsASymlinkedFolderOnce() throws {
        let home = tempHome()
        write("{}", to: home + "/.codex-real/auth.json")
        try FileManager.default.createSymbolicLink(atPath: home + "/.codex-work", withDestinationPath: ".codex-real")
        #expect(Discovery.find(home: home).filter { $0.tool == .codex }.map(\.configDir) == ["~/.codex-real"])
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
        write("alias claude=\"$HOME/.claude/local/claude\"\nalias codex='codex --yolo'\nalias opencode='FOO=1 opencode'\nalias ll='ls -l'\n"
              + "alias codex='nocorrect codex'\nalias opencode='noglob opencode run'\n",
              to: home + "/.zshrc")
        let found = ShellInit.bypassingAliases(.zsh, home: home)
        #expect(found.map(\.command) == ["claude"])
        #expect(found.first?.target == "$HOME/.claude/local/claude")
    }

    @Test func aSymlinkedStartupFileStaysALink() throws {
        let home = tempHome()
        write("export A=1\n", to: home + "/dotfiles/zshrc")
        try FileManager.default.createSymbolicLink(atPath: home + "/.zshrc", withDestinationPath: "dotfiles/zshrc")
        #expect(try ShellInit.installHook(.zsh, home: home) == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.zshrc") == "dotfiles/zshrc")
        #expect(try String(contentsOfFile: home + "/dotfiles/zshrc", encoding: .utf8).hasSuffix(#"eval "$(acc shell-init zsh)""# + "\n"))
    }
}

@Suite struct SyncAll {
    @Test func syncsEveryOtherAccountAndKeepsGoingPastAFailure() throws {
        let home = tempHome()
        write("model = 1", to: home + "/.codex/config.toml")
        try FileManager.default.createDirectory(atPath: home + "/.codex-ro", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home + "/.codex-ro")
        let r = Registry(current: [.codex: "main"], accounts: [
            Account(id: "ro", tool: .codex, label: "RO", configDir: home + "/.codex-ro"),
            Account(id: "main", tool: .codex, label: "Main", configDir: nil),
            Account(id: "side", tool: .codex, label: "Side", configDir: home + "/.codex-side"),
        ])
        let results = Shared.syncAll(r, runners: [:], prune: false, home: home)
        #expect(results.map(\.account.id) == ["ro", "side"])
        #expect(results.allSatisfy { $0.primary.id == "main" })
        #expect(throws: (any Error).self) { try results[0].result.get() }
        #expect(try results[1].result.get() == ["linked config.toml"])
    }
}

@Suite struct MostLeft {
    @Test func picksTheRoomiestOfEachToolWithUsageOnRecord() {
        let readings = ["personal": usage(30), "cto": usage(80)]
        #expect(sample.mostLeft(readings, at: t0).map(\.id) == ["personal"])
        #expect(sample.mostLeft(readings, tool: .codex, at: t0).isEmpty)
        #expect(sample.mostLeft(readings.merging(["side": usage(10)]) { $1 }, at: t0).map(\.id) == ["personal", "side"])
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
