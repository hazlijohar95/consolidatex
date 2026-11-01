import Foundation
import Testing
@testable import AccCore

@Suite struct CIDebug {
    @Test func dumpScan() throws {
        let home = tempHome()
        let fake = try fakeTool("claude", in: home)
        let session = try start(fake, ["30"], environment: ["CLAUDE_CONFIG_DIR": home + "/.claude-w"])
        defer { kill(session, SIGTERM) }
        let procs = RunningSessions.toolProcesses([ToolSpec.claude])
        var args = RunningSessions.ArgumentBuffer()
        let facts = args.facts(of: session, variables: ["CLAUDE_CONFIG_DIR"], flags: [])
        print("error-debug pid=\(session) self=\(getpid()) listed=\(procs[session] != nil) parent=\(procs[session].map { $0.parent } ?? -1)")
        print("error-debug ancestors=\(RunningSessions.ancestors(of: session)) facts=\(String(describing: facts?.variables))")
        print("error-debug canonical=\(canonical(home + "/.claude-w")) home=\(home)")
    }
}
