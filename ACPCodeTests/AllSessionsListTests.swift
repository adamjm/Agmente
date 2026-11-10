import Testing
import ACPClient
import Foundation
@testable import ACPCode

// D-113: the drawer's all-sessions rows (Fork/Sidebar/AllSessionsList.swift). Pure rules, no view.

struct AllSessionsListTests {
    private let serverA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let serverB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func session(_ id: String, _ title: String? = nil, at time: TimeInterval? = nil) -> SessionSummary {
        SessionSummary(id: id, title: title, cwd: nil, updatedAt: time.map { Date(timeIntervalSince1970: $0) })
    }

    private func server(
        _ id: UUID,
        name: String = "Server",
        agent: String? = nil,
        isCodex: Bool = false,
        isSelected: Bool = false,
        _ sessions: [SessionSummary]
    ) -> AllSessionsServerInput {
        AllSessionsServerInput(
            serverId: id,
            serverName: name,
            agentName: agent,
            isCodex: isCodex,
            isSelected: isSelected,
            sessions: sessions
        )
    }

    private func server(
        _ id: UUID,
        name: String = "Server",
        agent: String? = nil,
        isCodex: Bool = false,
        isSelected: Bool = false,
        _ session: SessionSummary
    ) -> AllSessionsServerInput {
        server(id, name: name, agent: agent, isCodex: isCodex, isSelected: isSelected, [session])
    }

    @Test func rowsAreNewestFirst() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, [session("s1", "one", at: 100), session("s2", "two", at: 300), session("s3", "three", at: 200)])
        ])
        #expect(rows.map(\.sessionId) == ["s2", "s3", "s1"])
    }

    @Test func sessionsWithoutADateGoLastInTheirInputOrder() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, [session("a"), session("b", at: 50), session("c"), session("d", at: 60)])
        ])
        #expect(rows.map(\.sessionId) == ["d", "b", "a", "c"])
        #expect(rows.last?.date == nil)
    }

    @Test func equalDatesKeepTheirInputOrder() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, [session("first", at: 70), session("second", at: 70)]),
            server(serverB, [session("third", at: 70)])
        ])
        #expect(rows.map(\.sessionId) == ["first", "second", "third"])
    }

    @Test func sessionsFromTwoServersAreInterleavedByDate() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, [session("a1", at: 10), session("a2", at: 30)]),
            server(serverB, [session("b1", at: 20), session("b2", at: 40)])
        ])
        #expect(rows.map(\.sessionId) == ["b2", "a2", "b1", "a1"])
        #expect(rows.map(\.serverId) == [serverB, serverA, serverB, serverA])
    }

    @Test func theSameSessionIdOnTwoServersStaysTwoRows() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, [session("shared", "A copy", at: 5)]),
            server(serverB, [session("shared", "B copy", at: 9)])
        ])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map(\.serverId) == [serverB, serverA])
    }

    @Test func emptyInputGivesNoRows() {
        #expect(AllSessionsList.rows(from: []).isEmpty)
        #expect(AllSessionsList.rows(from: [server(serverA, [])]).isEmpty)
    }

    @Test func rowCarriesTheConnectionAndAgentIdentity() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, name: "  Home box  ", agent: "Claude Code", isSelected: true, session("s1", "Fix", at: 1)),
            server(serverB, name: "", isCodex: true, session("s2", at: 2))
        ])
        let claude = rows.first { $0.sessionId == "s1" }
        #expect(claude?.connectionName == "Home box")
        #expect(claude?.agentName == "Claude Code")
        #expect(claude?.builder == .claude)
        #expect(claude?.isSelectedServer == true)
        #expect(claude?.title == "Fix")

        let codex = rows.first { $0.sessionId == "s2" }
        #expect(codex?.connectionName == "Connection")
        #expect(codex?.builder == .codex)
        #expect(codex?.isSelectedServer == false)
        #expect(codex?.title == AllSessionsList.untitledTitle)
    }

    @Test func accessibilityIdentifierNamesServerAndSession() {
        let rows = AllSessionsList.rows(from: [server(serverA, [session("abc", "Title", at: 1)])])
        #expect(rows.first?.accessibilityIdentifier == "allSessionRow_\(serverA.uuidString)_abc")
        #expect(rows.first?.id == AllSessionRow.key(serverId: serverA, sessionId: "abc"))
    }

    @Test func queryKeepsTitlesAndIdsThatContainIt() {
        let servers = [
            server(serverA, [session("s-alpha", "Deploy the API", at: 3), session("s-beta", "Docs", at: 2)]),
            server(serverB, [session("GAMMA-9", "Notes", at: 1)])
        ]
        #expect(AllSessionsList.rows(from: servers, query: "deploy").map(\.sessionId) == ["s-alpha"])
        #expect(AllSessionsList.rows(from: servers, query: "gamma").map(\.sessionId) == ["GAMMA-9"])
        #expect(AllSessionsList.rows(from: servers, query: "   ").count == 3)
        #expect(AllSessionsList.rows(from: servers, query: "nothing-matches").isEmpty)
    }

    @Test func selectedServerRowsAreNotDroppedByTheModel() {
        let rows = AllSessionsList.rows(from: [
            server(serverA, isSelected: true, session("s1", at: 1)),
            server(serverB, session("s2", at: 2))
        ])
        #expect(rows.map(\.isSelectedServer) == [false, true])
    }
}
