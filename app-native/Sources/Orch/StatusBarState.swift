import Foundation

class StatusBarState {
    var currentIssue: Issue?
    var gitBranch: String = ""
    var gitDirty: Bool = false
    var contextTokens: Int = 0
    var contextLimit: Int = 1_000_000
    var contextModel: String?
    // Claude's own used_percentage when it reports one, so the dot and the label
    // agree with `/context` rather than with our own division.
    var contextFraction: Double = 0
    var costUSD: Double = 0
    var burnUSDPerHour: Double = 0
    var bgAgents: Int = 0
    var gitAhead: Int = 0
    var gitBehind: Int = 0
    var diffAdded: Int = 0
    var diffRemoved: Int = 0
    var prNumber: Int = 0          // 0 = no open PR
    var prChecks: String = ""      // "passing" | "failing" | "pending" | ""
}
