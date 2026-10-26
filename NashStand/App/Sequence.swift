import SwiftUI

/// One step of a song's road map: "C×2" is the chorus twice. Anything typed, like "C (down)", is kept as is.
struct SequenceStep: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var count = 1

    var label: String { count > 1 ? "\(name)×\(count)" : name }

    /// Splits "Intro, V1, C×2, Tag" into steps.
    static func parse(_ sequence: String) -> [SequenceStep] {
        sequence.split(separator: ",").compactMap { part in
            let text = part.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let match = text.wholeMatch(of: #/(.+?)\s*[×x](\d+)/#), let count = Int(match.2), count > 1 {
                return SequenceStep(name: String(match.1), count: count)
            }
            return SequenceStep(name: text)
        }
    }

    static func join(_ steps: [SequenceStep]) -> String { steps.map(\.label).joined(separator: ", ") }
}

/// Edits a song's sequence on the stand: tap to add, drag to reorder, swipe or ⊖ to remove.
struct SequenceEditor: View {
    let title: String
    /// What the Mac sent, for putting things back.
    let shared: String
    let current: String
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var steps: [SequenceStep] = []
    @State private var custom = ""
    @FocusState private var typing: Bool

    static let sections = ["Intro", "V1", "V2", "V3", "V4", "PC", "C", "C2", "Post", "B", "B1", "B2", "Inst", "Inst 1", "Inst 2", "Turn", "Interlude", "Refrain", "Vamp", "Breakdown", "Tag", "Outro", "End"]
    private static let directions = ["(down)", "(build)", "(a cappella)", "(drums only)", "(hold)"]

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            List {
                Section {
                    if steps.isEmpty {
                        Text("No sections yet. Tap the buttons below to add them in order.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($steps) { $step in
                        HStack {
                            Text(step.name).font(.title3.weight(.semibold))
                            Spacer()
                            Stepper(value: $step.count, in: 1...8) {
                                Text(step.count > 1 ? "×\(step.count)" : "once")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(step.count > 1 ? Theme.green : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                        .id(step.id)
                    }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { steps.remove(atOffsets: $0) }
                } header: {
                    Text(steps.isEmpty ? "Sequence" : SequenceStep.join(steps))
                        .textCase(nil)
                        .lineLimit(3)
                }

                Section {
                    chips(Self.directions) { direction in
                        guard let last = steps.indices.last else { return }
                        steps[last].name += " \(direction)"
                    }
                    .disabled(steps.isEmpty)
                } header: {
                    Text("Add to the last section")
                }

                if current != shared {
                    Section {
                        Button("Use the Mac’s sequence", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    } footer: {
                        Text(shared.isEmpty ? "The Mac sent no sequence for this song." : "From the Mac: \(shared)")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            // Section buttons stay put below the list, so adding never needs a scroll.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    chips(Self.sections) { name in
                        let step = SequenceStep(name: name)
                        steps.append(step)
                        withAnimation { scroller.scrollTo(step.id, anchor: .bottom) }
                    }
                    HStack {
                        TextField("Something else, like “C (down)” or “Spontaneous”", text: $custom)
                            .textFieldStyle(.roundedBorder)
                            .focused($typing)
                            .submitLabel(.done)
                            .onSubmit { addCustom(scroller) }
                        Button("Add") { addCustom(scroller) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.green)
                            .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)
            }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(SequenceStep.join(steps))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { steps = SequenceStep.parse(current) }
        .roomySheet()
    }

    private func addCustom(_ scroller: ScrollViewProxy) {
        let added = SequenceStep.parse(custom)
        guard let last = added.last else { return }
        steps.append(contentsOf: added)
        custom = ""
        withAnimation { scroller.scrollTo(last.id, anchor: .bottom) }
    }

    /// Big buttons that wrap, sized for a quick tap between songs.
    private func chips(_ labels: [String], action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Button { action(label) } label: {
                    Text(label)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.green)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension View {
    /// A taller sheet on iPad, so a long sequence and the section buttons fit together.
    @ViewBuilder func roomySheet() -> some View {
        if #available(iOS 18.0, *) { presentationSizing(.page) } else { self }
    }
}
