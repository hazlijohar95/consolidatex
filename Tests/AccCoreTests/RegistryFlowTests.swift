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
