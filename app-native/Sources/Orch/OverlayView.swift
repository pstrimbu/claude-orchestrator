import SwiftUI

struct OverlayView: View {
    @ObservedObject var overlay: OverlayManager

    var body: some View {
        if overlay.visible {
            ZStack {
                // Backdrop
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { overlay.handleKey("escape") }

                VStack(spacing: 0) {
                    // Title
                    HStack {
                        Text(overlay.title)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.03))

                    Divider().background(Color(hex: 0x444444))

                    if overlay.loading {
                        HStack {
                            Text("Loading...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(hex: 0x808080))
                            Spacer()
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                    }

                    if let msg = overlay.message {
                        HStack {
                            Text(msg)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(hex: 0xffd75f))
                            Spacer()
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                    }

                    // Items
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(overlay.items.enumerated()), id: \.offset) { idx, item in
                                    OverlayItemRow(
                                        item: item,
                                        selected: idx == overlay.selectedIdx,
                                        editing: idx == overlay.selectedIdx && overlay.editing
                                    )
                                    .id(idx)
                                    .onTapGesture {
                                        overlay.handleKey("click:\(idx)")
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .onChange(of: overlay.selectedIdx) { newIdx in
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }

                    if let footer = overlay.footer {
                        Divider().background(Color(hex: 0x444444))
                        HStack {
                            Text(footer)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: 0x5fd7ff))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                    }
                }
                .frame(width: CGFloat(overlay.overlayWidth ?? 50) * 8.5, alignment: .leading)
                .frame(maxHeight: 500)
                .background(Color(hex: 0x252525))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: 0x555555), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
            }
        }
    }
}

struct OverlayItemRow: View {
    let item: OverlayItem
    let selected: Bool
    let editing: Bool

    var body: some View {
        if item.label.isEmpty && item.value == nil {
            Color.clear.frame(height: 8)
        } else {
            HStack(spacing: 8) {
                if item.editable {
                    Text(item.label)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                    Text(editDisplayText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(editing ? Color(hex: 0x5fafff) : Color(hex: 0x444444), lineWidth: 1)
                        )
                        .cornerRadius(3)
                    if editing {
                        Text("\u{2588}")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: 0x5fafff))
                            .blinkAnimation()
                    }
                } else {
                    Text(item.label)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(item.dimmed && item.action == nil ? Color(hex: 0x808080) : .white)
                    Spacer()
                    if let value = item.value {
                        Text(value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: 0x808080))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color(hex: 0x5fafff).opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
    }

    private var editDisplayText: String {
        let val = item.editValue ?? ""
        if val.isEmpty { return item.placeholder ?? "" }
        return val
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

// MARK: - Blink animation

struct BlinkModifier: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    visible.toggle()
                }
            }
    }
}

extension View {
    func blinkAnimation() -> some View {
        modifier(BlinkModifier())
    }
}
