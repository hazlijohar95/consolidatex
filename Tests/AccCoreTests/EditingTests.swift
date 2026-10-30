import Foundation
import Testing
@testable import AccCore

@Suite struct Editing {
    @Test func addValidatesLikeTheCLI() throws {
        var r = sample
        try r.add(Account(id: "ops", label: "Ops", configDir: "~/.claude-ops"))
        #expect(r.accounts.last?.id == "ops")
        #expect(throws: AccError.duplicateID("ops")) { try r.add(Account(id: "ops", label: "x", configDir: "~/x")) }
        #expect(throws: AccError.invalidID("Ops!")) { try r.add(Account(id: "Ops!", label: "x", configDir: "~/x")) }
        #expect(throws: AccError.invalidID("sync")) { try r.add(Account(id: "sync", label: "x", configDir: "~/x")) }
    }

    @Test func addCannotCreateASecondDefault() {
        var r = sample
        #expect(throws: (any Error).self) { try r.add(Account(id: "two", label: "Two", configDir: nil)) }
        #expect(r == sample)
    }

    @Test func renameTrimsAndRejectsEmpty() throws {
        var r = sample
        try r.rename("cto", to: "  Chief  ")
        #expect(r.account(id: "cto")?.label == "Chief")
        #expect(throws: AccError.usage("a label cannot be empty")) { try r.rename("cto", to: "  ") }
        #expect(throws: AccError.noMatch("nope")) { try r.rename("nope", to: "x") }
    }

    @Test func removeGuardsCurrentAndPrimary() throws {
        var r = sample
        #expect(throws: (any Error).self) { try r.remove("cto") }
        #expect(throws: (any Error).self) { try r.remove("team") }
        try r.remove("hello")
        #expect(r.accounts.map(\.id) == ["team", "personal", "cto"])
    }

    @Test func moveReorders() {
        var r = sample
        r.move(from: 3, to: 0)
        #expect(r.accounts.map(\.id) == ["hello", "team", "personal", "cto"])
        r.move(from: 0, to: 99)
        #expect(r.accounts.map(\.id) == ["team", "personal", "cto", "hello"])
    }

    @Test func suggestedIDs() {
        #expect(sample.suggestedID(for: "Hello Team!") == "hello-team")
        #expect(sample.suggestedID(for: "CTO") == "cto-2")
        #expect(sample.suggestedID(for: "A&H") == "a-h")
        #expect(sample.suggestedID(for: "42") == "acc-42")
        #expect(sample.suggestedID(for: "Sync") == "sync-2")
        #expect(sample.suggestedID(for: "🙂") == "acc")
        #expect(Registry.isValidID(sample.suggestedID(for: "  --Weird__Name--  ")))
    }
}
