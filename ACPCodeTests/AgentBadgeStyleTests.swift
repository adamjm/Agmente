import Testing
import UIKit
@testable import ACPCode

// D-113: agent builder detection and the pastel badge colours (Fork/Agents/AgentBadgeStyle.swift). Pure logic.

struct AgentBadgeStyleTests {
    // MARK: Detection by agent name

    @Test func eachBuilderIsDetectedFromItsAgentName() {
        #expect(AgentBuilder.detect(agentName: "IBM Bob", serverName: nil, isCodex: false) == .bob)
        #expect(AgentBuilder.detect(agentName: "Claude Code", serverName: nil, isCodex: false) == .claude)
        #expect(AgentBuilder.detect(agentName: "codex-acp", serverName: nil, isCodex: false) == .codex)
        #expect(AgentBuilder.detect(agentName: "Gemini CLI", serverName: nil, isCodex: false) == .gemini)
        #expect(AgentBuilder.detect(agentName: "opencode", serverName: nil, isCodex: false) == .opencode)
        #expect(AgentBuilder.detect(agentName: "oh-my-pi", serverName: nil, isCodex: false) == .ohMyPi)
        #expect(AgentBuilder.detect(agentName: "GitHub Copilot", serverName: nil, isCodex: false) == .copilot)
        #expect(AgentBuilder.detect(agentName: "Qwen Code", serverName: nil, isCodex: false) == .qwen)
        #expect(AgentBuilder.detect(agentName: "goose", serverName: nil, isCodex: false) == .goose)
    }

    @Test func nameMatchingIgnoresCase() {
        #expect(AgentBuilder.detect(agentName: "CLAUDE", serverName: nil, isCodex: false) == .claude)
        #expect(AgentBuilder.detect(agentName: "bOb", serverName: nil, isCodex: false) == .bob)
        #expect(AgentBuilder.detect(agentName: "OpenCode", serverName: nil, isCodex: false) == .opencode)
    }

    @Test func shortTokensMatchOnlyAsWholeWords() {
        #expect(AgentBuilder.detect(agentName: "pi", serverName: nil, isCodex: false) == .ohMyPi)
        #expect(AgentBuilder.detect(agentName: "@mariozechner/pi-coding-agent", serverName: nil, isCodex: false) == .ohMyPi)
        #expect(AgentBuilder.detect(agentName: "omp", serverName: nil, isCodex: false) == .ohMyPi)
        #expect(AgentBuilder.detect(agentName: "pipeline", serverName: nil, isCodex: false) == .unknown)
        #expect(AgentBuilder.detect(agentName: "epic", serverName: nil, isCodex: false) == .unknown)
    }

    @Test func copilotIsNotOhMyPi() {
        #expect(AgentBuilder.detect(agentName: "copilot", serverName: nil, isCodex: false) == .copilot)
        #expect(AgentBuilder.detect(agentName: "copilot", serverName: nil, isCodex: false) != .ohMyPi)
    }

    @Test func agentNameBeatsTheCodexFlag() {
        #expect(AgentBuilder.detect(agentName: "Claude", serverName: nil, isCodex: true) == .claude)
    }

    // MARK: Codex flag and server name

    @Test func nilOrEmptyNameWithCodexFlagIsCodex() {
        #expect(AgentBuilder.detect(agentName: nil, serverName: nil, isCodex: true) == .codex)
        #expect(AgentBuilder.detect(agentName: "", serverName: nil, isCodex: true) == .codex)
        #expect(AgentBuilder.detect(agentName: "   ", serverName: "Home", isCodex: true) == .codex)
    }

    @Test func serverNameIsTheFallbackWhenTheAgentNameDoesNotMatch() {
        #expect(AgentBuilder.detect(agentName: nil, serverName: "Claude Home", isCodex: false) == .claude)
        #expect(AgentBuilder.detect(agentName: "acpcode-gateway", serverName: "Bob Gateway", isCodex: false) == .bob)
        #expect(AgentBuilder.detect(agentName: nil, serverName: "Work laptop", isCodex: false) == .unknown)
    }

    @Test func unknownWhenNothingMatches() {
        #expect(AgentBuilder.detect(agentName: nil, serverName: nil, isCodex: false) == .unknown)
        #expect(AgentBuilder.detect(agentName: "  ", serverName: "  ", isCodex: false) == .unknown)
    }

    // MARK: Hue

    @Test func unknownNameHueIsStableAcrossCallsAndCase() {
        let first = AgentBadgeStyle.pastel(for: .unknown, agentName: "Acme Agent")
        let second = AgentBadgeStyle.pastel(for: .unknown, agentName: "Acme Agent")
        let lowered = AgentBadgeStyle.pastel(for: .unknown, agentName: "acme agent")
        #expect(first == second)
        #expect(first == lowered)
    }

    @Test func unknownNameHashIsFixedFNV1a() {
        // FNV-1a 32-bit of "acme agent" is 3420891582, and 3420891582 % 6 == 0. Locks the hash across launches.
        #expect(AgentBadgeStyle.stableIndex(for: "acme agent", count: 6) == 0)
        #expect(AgentBadgeStyle.pastel(for: .unknown, agentName: "Acme Agent") == AgentBadgeStyle.unknownPalette[0])
    }

    @Test func unknownWithoutNameUsesOneNeutralHue() {
        #expect(AgentBadgeStyle.pastel(for: .unknown, agentName: nil) == AgentBadgeStyle.pastel(for: .unknown, agentName: ""))
    }

    @Test func knownBuildersHaveDistinctHues() {
        let builders = AgentBuilder.allCases.filter { $0 != .unknown }
        let backgrounds = Set(builders.map { AgentBadgeStyle.pastel(for: $0, agentName: nil).background })
        #expect(backgrounds.count == builders.count)
        let foregrounds = Set(builders.map { AgentBadgeStyle.pastel(for: $0, agentName: nil).foreground })
        #expect(foregrounds.count == builders.count)
    }

    @Test func everyPastelKeepsContrastInLightAndDarkMode() {
        var pastels = AgentBuilder.allCases.map { AgentBadgeStyle.pastel(for: $0, agentName: nil) }
        pastels += AgentBadgeStyle.unknownPalette
        for pastel in pastels {
            #expect(pastel.foreground.contrastRatio(with: pastel.background) >= 4.5)
            #expect(pastel.darkForeground.contrastRatio(with: pastel.darkBackground) >= 4.5)
        }
    }

    @Test func everyBuilderHasAnExistingSymbolAndAName() {
        for builder in AgentBuilder.allCases {
            #expect(!builder.displayName.isEmpty)
            #expect(UIImage(systemName: builder.symbolName) != nil, "missing symbol \(builder.symbolName)")
        }
    }

    @Test func stableIndexStaysInRange() {
        for name in ["", "a", "claude", "a very long agent name with spaces"] {
            let index = AgentBadgeStyle.stableIndex(for: name, count: AgentBadgeStyle.unknownPalette.count)
            #expect(index >= 0 && index < AgentBadgeStyle.unknownPalette.count)
        }
    }
}
