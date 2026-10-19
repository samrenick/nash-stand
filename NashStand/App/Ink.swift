import PencilKit
import SwiftUI

enum InkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, cover, eraser
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlight"
        case .cover: "White-out"
        case .eraser: "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .cover: "rectangle.portrait.fill"
        case .eraser: "eraser"
        }
    }
}

enum InkSize: CaseIterable {
    case fine, medium, bold

    /// Stroke width in PDF points, so marks look the same in portrait and landscape.
    func width(for tool: InkTool) -> CGFloat {
        switch tool {
        case .pen: [1.6, 2.6, 4.2][index]
        case .highlighter: [8, 12, 18][index]
        case .cover: [8, 14, 24][index]
        case .eraser: 0
        }
    }

    var dot: CGFloat { [7, 11, 16][index] }
    var next: InkSize { Self.allCases[(index + 1) % Self.allCases.count] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// Current tool choices plus the page being written on, shared by the toolbar and the pages.
@MainActor
final class InkSettings: ObservableObject {
    static let penColors: [UIColor] = [
        UIColor(red: 0.85, green: 0.16, blue: 0.14, alpha: 1),
        UIColor(red: 0.09, green: 0.11, blue: 0.10, alpha: 1),
        UIColor(red: 0.10, green: 0.36, blue: 0.82, alpha: 1),
        UIColor(red: 0.12, green: 0.55, blue: 0.27, alpha: 1),
        UIColor(red: 0.93, green: 0.48, blue: 0.05, alpha: 1),
        UIColor(red: 0.50, green: 0.24, blue: 0.75, alpha: 1),
    ]
    static let highlighterColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.88, blue: 0.10, alpha: 1),
        UIColor(red: 0.45, green: 0.90, blue: 0.40, alpha: 1),
        UIColor(red: 1.00, green: 0.45, blue: 0.70, alpha: 1),
        UIColor(red: 0.35, green: 0.75, blue: 1.00, alpha: 1),
    ]

    @Published var isMarkingUp = false
    @Published var tool: InkTool = .pen
    @Published var penColor = penColors[0]
    @Published var highlighterColor = highlighterColors[0]
    @Published var size: InkSize = .medium
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Set during SwiftUI view updates, so the history refresh waits until the update finishes.
    weak var activePage: PageController? {
        didSet {
            guard oldValue !== activePage else { return }
            DispatchQueue.main.async { [weak self] in self?.refreshHistory() }
        }
    }

    func pkTool(scale: CGFloat) -> PKTool {
        let width = size.width(for: tool) * max(scale, 0.1)
        switch tool {
        case .pen: return PKInkingTool(.pen, color: penColor, width: width)
        case .highlighter: return PKInkingTool(.marker, color: highlighterColor, width: width)
        case .cover: return PKInkingTool(.pen, color: .white, width: width)
        // Whole-stroke erasing: touching any part of a mark removes it, which is forgiving with a blunt stylus.
        case .eraser: return PKEraserTool(.vector)
        }
    }

    func undo() { activePage?.undo() }
    func redo() { activePage?.redo() }
    func clearPage() { activePage?.clear() }

    func refreshHistory() {
        let undo = activePage?.canUndo ?? false, redo = activePage?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
}

/// The marking-up toolbar, sized for fingers and blunt styluses.
struct InkToolbar: View {
    @ObservedObject var ink: InkSettings
    @State private var confirmingClear = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(InkTool.allCases) { tool in
                    ToolButton(label: tool.label, symbol: tool.symbol, selected: ink.tool == tool) { ink.tool = tool }
                }
                divider
                if ink.tool == .pen || ink.tool == .highlighter {
                    let colors = ink.tool == .pen ? InkSettings.penColors : InkSettings.highlighterColors
                    let selected = ink.tool == .pen ? ink.penColor : ink.highlighterColor
                    ForEach(colors, id: \.self) { color in
                        Button {
                            if ink.tool == .pen { ink.penColor = color } else { ink.highlighterColor = color }
                        } label: {
                            Circle()
                                .fill(Color(color))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().stroke(Color.white, lineWidth: selected == color ? 3 : 0))
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                                .frame(width: 40, height: 52)
                        }
                        .accessibilityLabel("Color")
                    }
                }
                if ink.tool != .eraser {
                    Button { ink.size = ink.size.next } label: {
                        VStack(spacing: 4) {
                            Circle().fill(Color.white).frame(width: ink.size.dot, height: ink.size.dot).frame(height: 22)
                            Text("Size").font(.caption2.weight(.medium))
                        }
                        .frame(width: 52, height: 52)
                    }
                    divider
                }
                ToolButton(label: "Undo", symbol: "arrow.uturn.backward", selected: false) { ink.undo() }
                    .disabled(!ink.canUndo)
                ToolButton(label: "Redo", symbol: "arrow.uturn.forward", selected: false) { ink.redo() }
                    .disabled(!ink.canRedo)
                ToolButton(label: "Clear", symbol: "trash", selected: false) { confirmingClear = true }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 68)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.92))
        .confirmationDialog("Erase everything you wrote on this page?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear page", role: .destructive) { ink.clearPage() }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 36).padding(.horizontal, 4)
    }
}

struct ToolButton: View {
    let label: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(height: 22)
                Text(label).font(.caption2.weight(.medium))
            }
            .frame(width: 56, height: 52)
            .background(selected ? Theme.lime : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(selected ? Theme.green : Color.white)
        }
    }
}
