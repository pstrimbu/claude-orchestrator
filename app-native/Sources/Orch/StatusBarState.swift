import Foundation

class StatusBarState {
    var currentIssue: Issue?
    var gitBranch: String = ""
    var gitDirty: Bool = false
    var contextTokens: Int = 0
    var contextLimit: Int = 1_000_000
    var contextModel: String?
    var costUSD: Double = 0
    var burnRate: Int = 0          // tokens/min
    var bgAgents: Int = 0
    var gitAhead: Int = 0
    var gitBehind: Int = 0
    var diffAdded: Int = 0
    var diffRemoved: Int = 0
    var prNumber: Int = 0          // 0 = no open PR
    var prChecks: String = ""      // "passing" | "failing" | "pending" | ""
    var usage24h: [Int] = []       // 24 hourly token buckets, oldest→newest
}
