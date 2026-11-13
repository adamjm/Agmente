import Testing
import ACPClient
import Foundation
@testable import ACPCode

// D-113: each connection's colour and connection state, carried on its drawer rows (Fork/Sidebar/ServerColour.swift).

struct ServerColourTests {
    @Test func firstConnectionGetsTheFirstColour() {
        #expect(ServerColour.paletteIndex(position: 0) == 0)
    }

    @Test func colourPositionsFollowTheListOrder() {
        #expect(ServerColour.paletteIndex(position: 1) == 1)
        #expect(ServerColour.paletteIndex(position: 3) == 3)
    }

    @Test func paletteWrapsAfterTheLastColour() {
        #expect(ServerColour.paletteIndex(position: ServerColour.palette.count) == 0)
        #expect(ServerColour.paletteIndex(position: ServerColour.palette.count + 2) == 2)
    }

    @Test func noConnectionMapsToTheFirstColour() {
        #expect(ServerColour.paletteIndex(position: -1) == 0)
    }

    @Test func colourIndexNeverLeavesThePalette() {
        for position in -3...40 {
            let index = ServerColour.paletteIndex(position: position)
            #expect(index >= 0 && index < ServerColour.palette.count)
        }
        #expect(ServerColour.palette.count > 0)
    }

    @Test func drawerRowsCarryTheConnectionStateAndColour() {
        let id = UUID()
        let input = AllSessionsServerInput(
            serverId: id,
            serverName: "Mac",
            agentName: nil,
            isCodex: false,
            isSelected: false,
            sessions: [SessionSummary(id: "s1", title: "Fix login", cwd: nil, updatedAt: nil)],
            isConnected: true,
            colourPosition: 2
        )
        let rows = AllSessionsList.rows(from: [input])
        #expect(rows.count == 1)
        #expect(rows.first?.isConnected == true)
        #expect(rows.first?.colourIndex == 2)
    }

    @Test func offlineConnectionRowsAreNotConnected() {
        let input = AllSessionsServerInput(
            serverId: UUID(),
            serverName: "Office",
            agentName: nil,
            isCodex: false,
            isSelected: false,
            sessions: [SessionSummary(id: "s2", title: nil, cwd: nil, updatedAt: nil)]
        )
        let rows = AllSessionsList.rows(from: [input])
        #expect(rows.first?.isConnected == false)
        #expect(rows.first?.colourIndex == 0)
    }

    @Test func everyConnectionsSessionsAppearTogether() {
        let first = AllSessionsServerInput(
            serverId: UUID(),
            serverName: "A",
            agentName: nil,
            isCodex: false,
            isSelected: true,
            sessions: [SessionSummary(id: "a1", title: "One", cwd: nil, updatedAt: nil)],
            isConnected: true,
            colourPosition: 0
        )
        let second = AllSessionsServerInput(
            serverId: UUID(),
            serverName: "B",
            agentName: nil,
            isCodex: false,
            isSelected: false,
            sessions: [SessionSummary(id: "b1", title: "Two", cwd: nil, updatedAt: nil)],
            isConnected: false,
            colourPosition: 1
        )
        let rows = AllSessionsList.rows(from: [first, second])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.connectionName)) == ["A", "B"])
        #expect(Set(rows.map(\.colourIndex)) == [0, 1])
    }
}
