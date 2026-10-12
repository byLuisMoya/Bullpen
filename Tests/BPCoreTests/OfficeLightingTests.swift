import BPCore
import Testing

@Suite struct OfficeLightingTests {
    @Test(arguments: [(0, OfficeLighting.off), (1, .singleDesk), (2, .allOn), (7, .allOn)])
    func lightingFollowsWorktreeCount(count: Int, expected: OfficeLighting) {
        #expect(OfficeLighting(activeWorktrees: count) == expected)
    }

    @Test func needsYouSortsFirst() {
        let sorted = AgentState.allCases.sorted { $0.attentionRank < $1.attentionRank }
        #expect(sorted.first == .needsYou)
        #expect(sorted.last == .dead)
    }
}
