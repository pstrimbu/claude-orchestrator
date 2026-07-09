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
}

class StatusBarModel: ObservableObject {
    @Published var data = StatusBarData()
    var onSectionClick: ((String) -> Void)?
}

struct StatusBarView: View {
    @ObservedObject var model: StatusBarModel

    var body: some View {
        HStack(spacing: 0) {
            // Claude activity dot
            sectionButton("project") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.data.claudeActive ? Color(hex: 0xd11a1a) : Color(hex: 0x1a7f37))
                        .frame(width: 8, height: 8)
                    Text(model.data.projectName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: 0x1f2937))
                }
            }

            separator

            // Time
            sectionButton("time") {
                HStack(spacing: 6) {
                    Text(model.data.timeRecording ? "\u{25cf}" : "\u{25cb}")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(model.data.timeRecording ? Color(hex: 0x1a7f37) : Color(hex: 0x6b7280))
                    Text(model.data.timeElapsed)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: 0x1f2937))
                }
            }

            separator

            // Issues
            sectionButton("issues") {
                HStack(spacing: 6) {
                    Text(issueText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: 0x1f2937))
                        .lineLimit(1)
                }
            }

            separator

            // Git
            sectionButton("git") {
                HStack(spacing: 6) {
                    Text(gitText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: 0x1f2937))
                }
            }

            separator

            // Sessions
            sectionButton("sessions") {
                HStack(spacing: 6) {
                    Text(model.data.sessionLabel.isEmpty ? "Session" : model.data.sessionLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: 0x1f2937))
                        .lineLimit(1)
                }
            }

            separator

            // Remote control — inject /remote-control so this session can be
            // steered from the Claude mobile app (QR/URL prints in the terminal).
            sectionButton("remote") {
                HStack(spacing: 5) {
                    Image(systemName: model.data.remoteActive
                          ? "antenna.radiowaves.left.and.right.circle.fill"
                          : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(model.data.remoteActive ? Color(hex: 0x1a7f37) : Color(hex: 0x2563eb))
                    Text(model.data.remoteActive ? "Remote ON" : "Remote")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(model.data.remoteActive ? Color(hex: 0x1a7f37) : Color(hex: 0x2563eb))
                }
            }

            Spacer()

            // Last command
            sectionButton("history") {
                Text(model.data.lastCommand ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: 0x6b7280))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(hex: 0xffffff))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(hex: 0xd1d5db))
                .frame(height: 1)
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
            } else {
                NSCursor.pop()
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
