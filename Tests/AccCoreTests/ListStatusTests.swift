import Foundation
import Testing
@testable import AccCore

/// Usage fixtures for ListStatus tests.
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let oneHour: TimeInterval = 3600
private let oneDay: TimeInterval = 86400

/// A capped account: 5h window at 100%.
private let cappedUsage = Usage(
    windows: [
        .init(minutes: 300, usedPercentage: 100, resetsAt: now + oneHour),
        .init(minutes: 10_080, usedPercentage: 60, resetsAt: now + 3 * oneDay),
    ],
    recordedAt: now - 60
)

/// Fable-only capped: the shared windows are fine, but the per-model Fable window is 100 %.
private let fableOnlyCappedUsage = Usage(
    windows: [
        .init(minutes: 300, usedPercentage: 10, resetsAt: now + oneHour),
        .init(minutes: 10_080, model: "Fable", usedPercentage: 100, resetsAt: now + 3 * oneDay),
    ],
    recordedAt: now - 60
)

/// A registry with three accounts: capped, Fable-only-capped, and one with no reading.
private let registry = Registry(
    current: [.claude: "capped"],
    accounts: [
        Account(id: "capped", tool: .claude, label: "Capped", configDir: "~/.claude-capped"),
        Account(id: "fable-only", tool: .claude, label: "Fable Only", configDir: "~/.claude-fable"),
        Account(id: "unknown", tool: .claude, label: "Unknown", configDir: "~/.claude-unknown"),
    ]
)

@Suite struct ListStatusBuild {
    let status = ListStatus.build(
        registry: registry,
        usages: ["capped": cappedUsage, "fable-only": fableOnlyCappedUsage],
        running: [:],
        now: now
    )

    @Test func accountCountMatchesRegistry() {
        #expect(status.accounts.count == 3)
    }

    @Test func cappedAccountIsMarkedCapped() {
        let a = status.accounts.first { $0.id == "capped" }!
        #expect(a.usage?.capped == true)
        #expect(a.usage?.load == 100)
    }

    @Test func fableOnlyCappedIsNotCapped() {
        let a = status.accounts.first { $0.id == "fable-only" }!
        #expect(a.usage?.capped == false)
        #expect(a.usage?.load == 10)
    }

    @Test func unknownAccountHasNilUsage() {
        let a = status.accounts.first { $0.id == "unknown" }!
        #expect(a.usage == nil)
    }

    @Test func currentFlagFollowsRegistry() {
        #expect(status.accounts.first { $0.id == "capped" }?.current == true)
        #expect(status.accounts.first { $0.id == "fable-only" }?.current == false)
    }

    @Test func rankOneIsLeastLoaded() {
        // fable-only has shared load 10%, unknown ranks as 50% (default), capped is 100%.
        let fable = status.accounts.first { $0.id == "fable-only" }!
        let unknown = status.accounts.first { $0.id == "unknown" }!
        let capped = status.accounts.first { $0.id == "capped" }!
        #expect(fable.rank == 1)
        #expect(unknown.rank == 2)
        #expect(capped.rank == 3)
    }

    @Test func windowUsedIsZeroAfterReset() {
        // A window whose resetsAt is in the past has used == 0.
        let pastReset = Usage(windows: [.init(minutes: 300, usedPercentage: 80, resetsAt: now - 60)], recordedAt: now - 120)
        let s = ListStatus.build(registry: registry, usages: ["capped": pastReset, "fable-only": fableOnlyCappedUsage], running: [:], now: now)
        let a = s.accounts.first { $0.id == "capped" }!
        #expect(a.usage?.windows.first?.used == 0)
        #expect(a.usage?.load == 0)
    }

    @Test func roomiestSkipsCapped() {
        // capped is at 100%; fable-only is at 10% shared; unknown has no reading (50% default).
        // roomiest should not be capped.
        let roomiestID = status.roomiest[.claude]
        #expect(roomiestID != "capped")
    }

    @Test func configDirPathIsResolvedAbsolute() {
        let a = status.accounts.first { $0.id == "capped" }!
        #expect(a.configDirPath.hasPrefix("/"))
    }

    @Test func toolFilterLimitsAccounts() {
        let filtered = ListStatus.build(
            registry: registry,
            usages: ["capped": cappedUsage],
            running: [:],
            tool: .claude,
            now: now
        )
        #expect(filtered.accounts.allSatisfy { $0.tool == .claude })
        #expect(filtered.roomiest.keys.count == 1)
    }

    @Test func windowLabelsArePresent() {
        let a = status.accounts.first { $0.id == "fable-only" }!
        let labels = a.usage?.windows.map(\.label) ?? []
        #expect(labels.contains("5h"))
        #expect(labels.contains("7d Fable"))
    }
}
