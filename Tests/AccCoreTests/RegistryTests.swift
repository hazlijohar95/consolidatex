import Foundation
import Testing
@testable import AccCore

let sample = Registry(current: "cto", accounts: [
    Account(id: "team", label: "Haz (team)", configDir: nil, email: "hazli@cynco.io"),
    Account(id: "personal", label: "Haz (Personal)", configDir: "~/.claude-acc2", email: "hazli@cynco.io"),
    Account(id: "cto", label: "CTO", configDir: "~/.claude-acc4", email: "cto@cynco.io"),
    Account(id: "hello", label: "Hello", configDir: "/abs/hello", email: "hello@cynco.io"),
])

func tempStore() -> RegistryStore {
    RegistryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("acc-tests-\(UUID().uuidString)"))
}

@Suite struct Resolve {
    @Test func byPosition() throws { #expect(try sample.resolve("3").id == "cto") }
    @Test func byID() throws { #expect(try sample.resolve("hello").id == "hello") }
    @Test func byLabelCaseInsensitive() throws { #expect(try sample.resolve("haz (personal)").id == "personal") }
    @Test func byUniqueFragment() throws { #expect(try sample.resolve("pers").id == "personal") }
    @Test func byEmail() throws { #expect(try sample.resolve("cto@").id == "cto") }

    @Test func ambiguousFragmentNamesTheCandidates() {
        #expect(throws: AccError.ambiguous("haz", ["team", "personal"])) { try sample.resolve("haz") }
    }

    @Test func unknownAndOutOfRange() {
        #expect(throws: AccError.noMatch("nope")) { try sample.resolve("nope") }
        #expect(throws: AccError.noMatch("9")) { try sample.resolve("9") }
        #expect(throws: AccError.noMatch("0")) { try sample.resolve("0") }
        #expect(throws: AccError.noMatch("")) { try sample.resolve("") }
    }
}

@Suite struct Validate {
    func problems(_ change: (inout Registry) -> Void) -> [String] {
        var r = sample
        change(&r)
        do { try r.validate(); return [] } catch AccError.invalidRegistry(let p) { return p } catch { return ["\(error)"] }
    }

    @Test func sampleIsValid() throws { try sample.validate() }
    @Test func duplicateID() { #expect(problems { $0.accounts[1].id = "team" } == ["duplicate id 'team'"]) }
    @Test func currentMustExist() { #expect(problems { $0.current = "gone" } == ["current account 'gone' is not in the list"]) }
    @Test func reservedID() { #expect(problems { $0.accounts[3].id = "ls" } == ["id 'ls' is reserved for an acc command"]) }
    @Test func numericIDWouldShadowPositions() { #expect(problems { $0.accounts[3].id = "4" }.first?.hasPrefix("invalid id '4'") == true) }
    @Test func singleDefaultDir() { #expect(problems { $0.accounts[1].configDir = nil } == ["more than one account uses the default config dir (configDir: null)"]) }
    @Test func emptyLabel() { #expect(problems { $0.accounts[0].label = " " } == ["account 'team' has an empty label"]) }
    @Test func empty() { #expect(problems { $0.accounts = [] } == ["no accounts", "current account 'cto' is not in the list"]) }

    @Test func futureVersionIsRejected() {
        var r = sample
        r.version = 2
        #expect(throws: AccError.unsupportedVersion(2)) { try r.validate() }
    }
}

@Suite struct ConfigDir {
    @Test func defaultAccountLeavesVariableUnset() {
        #expect(sample.accounts[0].resolvedConfigDir(home: "/h") == nil)
        #expect(Claude.environment(for: sample.accounts[0], base: ["CLAUDE_CONFIG_DIR": "/stale", "X": "1"]) == ["X": "1"])
    }

    @Test func tildeExpands() {
        #expect(sample.accounts[2].resolvedConfigDir(home: "/h") == "/h/.claude-acc4")
        #expect(sample.accounts[3].resolvedConfigDir(home: "/h") == "/abs/hello")
    }
}

@Suite struct Store {
    @Test func roundTrip() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(try store.load() == sample)
    }

    @Test func missingFile() {
        let store = tempStore()
        #expect(throws: AccError.registryMissing(path: store.file.path)) { try store.load() }
    }

    @Test func invalidWriteLeavesFileUntouched() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(throws: (any Error).self) { try store.update { $0.current = "gone" } }
        #expect(try store.load() == sample)
    }

    @Test func failedChangeLeavesFileUntouched() throws {
        let store = tempStore()
        try store.save(sample)
        #expect(throws: AccError.noMatch("zzz")) { try store.update { $0.current = try $0.resolve("zzz").id } }
        #expect(try store.load().current == "cto")
    }

    @Test func malformedJSONNamesTheProblem() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"current":"a","accounts":[{"id":"a"}]}"#.utf8).write(to: store.file)
        #expect {
            try store.load()
        } throws: { error in
            guard case AccError.registryUnreadable(_, let reason) = error else { return false }
            return reason == "missing field 'label' at .accounts[0]"
        }
    }
}
