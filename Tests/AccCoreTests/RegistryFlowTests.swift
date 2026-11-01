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
