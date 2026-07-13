import SwiftUI

struct StatusBarData {
    var claudeActive = false
    var projectName = ""
    var timeElapsed = "0m"
    var timeRecording = false
    var trackerEnabled = false
    var trackerTeamKey: String?
    var currentIssueKey: String?
    var currentIssueTitle: String?
    var gitBranch = ""
    var gitDirty = false
    var sessionLabel = ""
    var lastCommand: String?
    var remoteActive = false
    var contextTokens = 0
    var contextLimit = 1_000_000
    var model = ""
    var costUSD = 0.0
    var burnRate = 0              // tokens/min
    var bgAgents = 0
    var gitAhead = 0
    var gitBehind = 0
    var diffAdded = 0
    var diffRemoved = 0
    var prNumber = 0
    var prChecks = ""            // "passing" | "failing" | "pending" | ""
    var attention = false        // Claude finished — awaiting your input (blinks)
}

class StatusBarModel: ObservableObject {
    @Published var data = StatusBarData()
    var onSectionClick: ((String) -> Void)?
}

struct StatusBarView: View {
    @ObservedObject var model: StatusBarModel
    @State private var blink = false
    /// Which section the pointer is over — used to expand chips that have more
    /// detail to show (full model id, issue title, full last command).
    @State private var hover = ""

    private let fg = Color(hex: 0x1f2937)
    private let dim = Color(hex: 0x6b7280)

    var body: some View {
        HStack(spacing: 0) {
            projectChip
            separator
            if !model.data.model.isEmpty { modelChip; separator }
            sizeChip
            if model.data.costUSD > 0 { costChip }
            if model.data.burnRate > 0 { burnChip }
            separator
            timeChip
            separator
            issuesChip
            separator
            gitChip
            if model.data.gitAhead > 0 { pushChip }
            if model.data.diffAdded > 0 || model.data.diffRemoved > 0 { diffChip }
            if model.data.prNumber > 0 { prChip }
            separator
            sessionsChip
            if model.data.bgAgents > 0 { agentsChip }
            separator
            remoteChip
            Spacer(minLength: 8)
            historyChip
            separator
            newSessionChip
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(hex: 0xffffff))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xd1d5db)).frame(height: 1)
        }
        .onReceive(Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()) { _ in
            blink.toggle()
        }
    }

    // MARK: - Chips

    private var projectChip: some View {
        sectionButton("project") {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .opacity(model.data.attention && blink ? 0.2 : 1)
                    .animation(.easeInOut(duration: 0.45), value: blink)
                Text(model.data.projectName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(fg)
            }
        }
    }

    private var dotColor: Color {
        if model.data.attention { return Color(hex: 0xd08700) }   // amber — your turn
        return model.data.claudeActive ? Color(hex: 0xd11a1a) : Color(hex: 0x1a7f37)
    }

    private var modelChip: some View {
        sectionButton("model") {
            // Compact short name; reveal the full model id on hover.
            Text(hover == "model" ? model.data.model : modelShort)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: 0x2563eb))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var sizeChip: some View {
        sectionButton("size") {
            HStack(spacing: 6) {
                Circle().fill(contextColor).frame(width: 8, height: 8)
                Text(contextLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(fg)
            }
        }
    }

    private var costChip: some View {
        sectionButton("size") {
            Text(costLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fg)
        }
        .help("Estimated session cost")
    }

    private var burnChip: some View {
        sectionButton("size") {
            Text("\(shortTokens(model.data.burnRate))/m")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dim)
        }
        .help("Token burn rate")
    }

    private var timeChip: some View {
        sectionButton("time") {
            HStack(spacing: 6) {
                Text(model.data.timeRecording ? "\u{25cf}" : "\u{25cb}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(model.data.timeRecording ? Color(hex: 0x1a7f37) : dim)
                Text(model.data.timeElapsed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(fg)
            }
        }
    }

    private var issuesChip: some View {
        sectionButton("issues") {
            // Show the issue key; reveal "KEY — title" on hover when available.
            Text(hover == "issues" && (model.data.currentIssueTitle?.isEmpty == false)
                 ? "\(issueText) \u{2014} \(model.data.currentIssueTitle!)"
                 : issueText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var gitChip: some View {
        sectionButton("git") {
            Text(gitText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(1)
        }
    }

    private var pushChip: some View {
        sectionButton("push") {
            Text("\u{2191}\(model.data.gitAhead)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: 0x1a7f37))
        }
        .help("Push \(model.data.gitAhead) commit(s)")
    }

    private var diffChip: some View {
        sectionButton("git") {
            HStack(spacing: 4) {
                Text("+\(model.data.diffAdded)")
                    .foregroundColor(Color(hex: 0x1a7f37))
                Text("\u{2212}\(model.data.diffRemoved)")
                    .foregroundColor(Color(hex: 0xd11a1a))
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .help("Working-tree changes")
    }

    private var prChip: some View {
        sectionButton("pr") {
            HStack(spacing: 4) {
                Text(prMark).foregroundColor(prColor)
                Text("#\(model.data.prNumber)").foregroundColor(fg)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .help("Open PR #\(model.data.prNumber)")
    }

    private var sessionsChip: some View {
        sectionButton("sessions") {
            Text("Session")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(fg)
                .lineLimit(1)
        }
    }

    private var agentsChip: some View {
        sectionButton("sessions") {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10))
                Text("\(model.data.bgAgents)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(Color(hex: 0x2563eb))
        }
        .help("\(model.data.bgAgents) background agent(s) running")
    }

    private var newSessionChip: some View {
        // Compact "+" — tighter than a normal section chip.
        Button(action: { model.onSectionClick?("newsession") }) {
            Text("+")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: 0x2563eb))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open a new orch session for this project")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var remoteChip: some View {
        sectionButton("remote") {
            HStack(spacing: 5) {
                Image(systemName: model.data.remoteActive
                      ? "antenna.radiowaves.left.and.right.circle.fill"
                      : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.data.remoteActive ? "Remote ON" : "Remote")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(model.data.remoteActive ? Color(hex: 0x1a7f37) : Color(hex: 0x2563eb))
        }
    }

    private var historyChip: some View {
        sectionButton("history") {
            // Truncate the last command by default (keeping the tail visible);
            // widen on hover to show more of it.
            Text(model.data.lastCommand ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dim)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: hover == "history" ? 520 : 200, alignment: .trailing)
        }
    }

    private var issueText: String {
        if let key = model.data.currentIssueKey { return key }
        if model.data.trackerEnabled { return model.data.trackerTeamKey ?? "Issues" }
        return "No tracker"
    }

    private var gitText: String {
        if model.data.gitBranch.isEmpty { return "\u{2014}" }
        return "\(model.data.gitBranch)\(model.data.gitDirty ? "*" : "")"
    }

    private var contextFraction: Double {
        let limit = model.data.contextLimit
        return limit > 0 ? Double(model.data.contextTokens) / Double(limit) : 0
    }

    private var contextColor: Color {
        if model.data.contextTokens <= 0 { return Color(hex: 0xc0c0c0) } // unknown / idle
        switch contextFraction {
        case ..<0.6:  return Color(hex: 0x1a7f37)  // green  — plenty of room
        case ..<0.85: return Color(hex: 0xd08700)  // amber  — getting full
        default:      return Color(hex: 0xd11a1a)  // red    — consolidate/restart soon
        }
    }

    private var contextLabel: String {
        let t = model.data.contextTokens
        if t <= 0 { return "\u{2014}" }
        let short = t >= 1_000_000
            ? String(format: "%.1fM", Double(t) / 1_000_000)
            : "\(Int((Double(t) / 1000).rounded()))k"
        return "\(short) \(Int((contextFraction * 100).rounded()))%"
    }

    private var modelShort: String {
        let m = model.data.model.lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        if m.contains("fable") { return "Fable" }
        if m.contains("mythos") { return "Mythos" }
        return model.data.model
    }

    private var costLabel: String {
        let c = model.data.costUSD
        if c >= 100 { return String(format: "$%.0f", c) }
        if c >= 10 { return String(format: "$%.1f", c) }
        return String(format: "$%.2f", c)
    }

    private func shortTokens(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return "\(Int((Double(t) / 1000).rounded()))k" }
        return "\(t)"
    }

    private var prMark: String {
        switch model.data.prChecks {
        case "passing": return "\u{2713}"   // ✓
        case "failing": return "\u{2717}"   // ✗
        case "pending": return "\u{25cf}"   // ●
        default:        return "\u{25cb}"   // ○
        }
    }

    private var prColor: Color {
        switch model.data.prChecks {
        case "passing": return Color(hex: 0x1a7f37)
        case "failing": return Color(hex: 0xd11a1a)
        case "pending": return Color(hex: 0xd08700)
        default:        return dim
        }
    }

    private var separator: some View {
        Text("\u{2502}")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(hex: 0xd1d5db))
            .padding(.horizontal, 4)
    }

    private func sectionButton(_ section: String, @ViewBuilder content: () -> some View) -> some View {
        Button(action: { model.onSectionClick?(section) }) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
                hover = section
            } else {
                NSCursor.pop()
                if hover == section { hover = "" }
            }
        }
    }
}

// MARK: - Color hex extension

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
