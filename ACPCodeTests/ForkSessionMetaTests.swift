import Testing
import ACPClient
@testable import ACPCode

/// FR-33 to FR-36 in the app: the session's plan, title and usage state, the usage line, the start
/// mode for a new session, and when `session/delete` is sent.
struct ForkSessionMetaTests {

    // MARK: - Plan, title and usage state (FR-33)

    @Test func planIsSetAndReplaced() {
        var meta = ForkSessionMeta()
        let first = [ACPPlanEntry(content: "A", status: .inProgress)]
        let second = [ACPPlanEntry(content: "B", status: .completed), ACPPlanEntry(content: "C", status: .pending)]
        let handledFirst = meta.apply(.planUpdate(entries: first))
        #expect(handledFirst)
        #expect(meta.plan == first)
        let handledSecond = meta.apply(.planUpdate(entries: second))
        #expect(handledSecond)
        #expect(meta.plan == second)
    }

    @Test func emptyPlanUpdateHidesThePlan() {
        var meta = ForkSessionMeta()
        meta.apply(.planUpdate(entries: [ACPPlanEntry(content: "A", status: .pending)]))
        meta.apply(.planUpdate(entries: []))
        #expect(meta.plan == nil)
    }

    @Test func planRemovedClearsThePlan() {
        var meta = ForkSessionMeta()
        meta.apply(.planUpdate(entries: [ACPPlanEntry(content: "A", status: .pending)]))
        meta.apply(.planRemoved)
        #expect(meta.plan == nil)
    }

    @Test func titleIsKeptUntilANewNonEmptyOne() {
        var meta = ForkSessionMeta()
        meta.apply(.sessionInfo(title: "First"))
        #expect(meta.title == "First")
        meta.apply(.sessionInfo(title: nil))
        #expect(meta.title == "First")
        meta.apply(.sessionInfo(title: "Second"))
        #expect(meta.title == "Second")
    }

    @Test func usageIsReplaced() {
        var meta = ForkSessionMeta()
        meta.apply(.usage(ACPSessionUsage(usedTokens: 10)))
        meta.apply(.usage(ACPSessionUsage(usedTokens: 20, contextSize: 100)))
        #expect(meta.usage == ACPSessionUsage(usedTokens: 20, contextSize: 100))
    }

    @Test func otherEventsAreNotHandled() {
        var meta = ForkSessionMeta()
        let handled = meta.apply(.agentMessage(text: "hi"))
        #expect(handled == false)
        #expect(meta == ForkSessionMeta())
    }

    @Test func planRowStateMapsUnknownToPending() {
        #expect(ForkPlanRowState(.pending) == .pending)
        #expect(ForkPlanRowState(.inProgress) == .inProgress)
        #expect(ForkPlanRowState(.completed) == .completed)
        #expect(ForkPlanRowState(.unknown("odd")) == .pending)
    }

    // MARK: - Usage line

    @Test func usageLineShowsTokensAndCost() {
        let line = ForkUsageFormat.line(ACPSessionUsage(usedTokens: 1200, contextSize: 200000, costAmount: 0.5, costCurrency: "USD"))
        #expect(line != nil)
        #expect(line?.contains("tokens") == true)
        #expect(line?.contains("USD") == true)
    }

    @Test func usageLineIsNilWithoutFigures() {
        #expect(ForkUsageFormat.line(nil) == nil)
        #expect(ForkUsageFormat.line(ACPSessionUsage()) == nil)
    }

    // MARK: - Start mode (FR-34)

    private let projects = [
        GatewayProject(id: "p1", name: "Root", path: "/work", defaultMode: "ask"),
        GatewayProject(id: "p2", name: "App", path: "/work/app", defaultMode: "plan"),
        GatewayProject(id: "p3", name: "Plain", path: "/work/plain", defaultMode: nil)
    ]

    @Test func startModeIsTheDefaultOfTheMatchingProject() {
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work", projects: projects) == "ask")
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/other", projects: projects) == "ask")
    }

    @Test func startModeUsesTheDeepestProjectOnly() {
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/app", projects: projects) == "plan")
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/app/src", projects: projects) == "plan")
    }

    @Test func startModeIsNilWithoutADefaultOrAMatch() {
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/plain", projects: projects) == nil)
        #expect(ForkSessionAgentRules.startMode(forCwd: "/elsewhere", projects: projects) == nil)
    }

    @Test func startModeDoesNotMatchAPrefixThatIsNotAFolder() {
        // "/work/application" is not inside "/work/app".
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/application", projects: projects) == "ask")
    }

    @Test func startModeIgnoresATrailingSlash() {
        #expect(ForkSessionAgentRules.startMode(forCwd: "/work/app/", projects: projects) == "plan")
    }

    // MARK: - Delete (FR-36)

    @Test func deleteIsSentOnlyWhenAgentAdvertisesItAndSessionExists() {
        var capable = AgentCapabilityState()
        capable.deleteSession = true
        #expect(ForkSessionAgentRules.sendsDeleteToAgent(capable, isPending: false))
        #expect(!ForkSessionAgentRules.sendsDeleteToAgent(capable, isPending: true))
        #expect(!ForkSessionAgentRules.sendsDeleteToAgent(AgentCapabilityState(), isPending: false))
    }
}
