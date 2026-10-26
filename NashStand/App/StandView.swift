import PDFKit
import SwiftUI

/// One page on the stand. A song without a chart gets a single placeholder page.
struct StandPage: Identifiable, Hashable {
    let slotIndex: Int
    let slot: SharedSlot
    let page: Int
    let pageCount: Int
    var id: String { "\(slot.id)-\(page)" }
    var isPlaceholder: Bool { !slot.hasChart }

    @MainActor static func pages(for setlist: SharedSetlist, store: Store) -> [StandPage] {
        setlist.songs.enumerated().flatMap { index, slot -> [StandPage] in
            let count = slot.hasChart ? (PDFDocument(url: store.chartURL(songId: slot.songId))?.pageCount ?? 0) : 0
            guard count > 0 else { return [StandPage(slotIndex: index, slot: slot, page: 0, pageCount: 1)] }
            return (0..<count).map { StandPage(slotIndex: index, slot: slot, page: $0, pageCount: count) }
        }
    }
}

struct StandView: View {
    let setlist: SharedSetlist
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ink = InkSettings()
    @State private var pages: [StandPage] = []
    @State private var index = 0
    /// Numbers or the chart as printed; remembered between setlists.
    @AppStorage("showOriginal") private var showOriginal = false
    @State private var editingSequence: SharedSlot?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // Shown above the page so it never covers the chart; tap it to change the sequence.
            sequenceStrip
            if !pages.isEmpty {
                PageReader(pages: pages, store: store, original: showOriginal, index: $index, ink: ink)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Spacer()
            }
            if ink.isMarkingUp { InkToolbar(ink: ink) }
        }
        .background(Theme.stand.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: ink.isMarkingUp)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            pages = StandPage.pages(for: setlist, store: store)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-markup") { ink.isMarkingUp = true }
            if ProcessInfo.processInfo.arguments.contains("-original") { showOriginal = true }
            if ProcessInfo.processInfo.arguments.contains("-editSequence") { editingSequence = pages.first?.slot }
            #endif
            // A music stand shouldn't dim mid-song.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $editingSequence) { slot in
            SequenceEditor(title: slot.title, shared: slot.sequence ?? "", current: store.sequence(for: slot, in: setlist)) {
                store.setSequence($0, for: slot, in: setlist)
            }
        }
    }

    private var current: StandPage? { pages.indices.contains(index) ? pages[index] : nil }

    private var nextSong: SharedSlot? {
        guard let current, current.page == current.pageCount - 1 else { return nil }
        return setlist.songs.indices.contains(current.slotIndex + 1) ? setlist.songs[current.slotIndex + 1] : nil
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Setlists", systemImage: "chevron.left").font(.body.weight(.semibold))
                }
                if hasOriginals { chartToggle }
            }
            .fixedSize()
            .frame(minWidth: 210, alignment: .leading)

            Spacer(minLength: 0)
            barButton("chevron.left", label: "Previous page") { index = max(0, index - 1) }
                .disabled(index == 0)
            songMenu
            barButton("chevron.right", label: "Next page") { index = min(pages.count - 1, index + 1) }
                .disabled(index >= pages.count - 1)
            Spacer(minLength: 0)

            Button { ink.isMarkingUp.toggle() } label: {
                Label(ink.isMarkingUp ? "Done" : "Mark up", systemImage: ink.isMarkingUp ? "checkmark" : "pencil.tip.crop.circle")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ink.isMarkingUp ? Theme.lime : Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(ink.isMarkingUp ? Theme.green : Color.white)
            }
            .fixedSize()
            .frame(minWidth: 210, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .foregroundStyle(.white)
        .background(Color.black)
    }

    private var songMenu: some View {
        Menu {
            ForEach(Array(setlist.songs.enumerated()), id: \.element.id) { songIndex, slot in
                Button {
                    if let first = pages.firstIndex(where: { $0.slotIndex == songIndex }) { index = first }
                } label: {
                    Text("\(songIndex + 1). \(slot.title)\(slot.hasChart ? "" : " (no chart)")")
                }
            }
        } label: {
            VStack(spacing: 1) {
                if let current {
                    Text("\(current.slotIndex + 1). \(current.slot.title)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(for: current))
                        .font(.caption)
                        .foregroundStyle(nextSong == nil ? Color.white.opacity(0.6) : Theme.lime)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 160, maxWidth: 360)
            .foregroundStyle(.white)
        }
    }

    private var hasOriginals: Bool { setlist.songs.contains { $0.hasOriginal == true } }

    private var sequenceStrip: some View {
        let slot = current?.slot
        let steps = slot.map { SequenceStep.parse(store.sequence(for: $0, in: setlist)) } ?? []
        let edited = slot.map { store.isSequenceEdited($0, in: setlist) } ?? false
        return Button { editingSequence = slot } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond")
                    .foregroundStyle(Theme.lime.opacity(steps.isEmpty ? 0.35 : 1))
                if steps.isEmpty {
                    Text("No sequence · tap to add").foregroundStyle(Color.white.opacity(0.4))
                } else {
                    Text(steps.map(\.label).joined(separator: "  →  "))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                if edited {
                    Text("Changed on iPad")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.lime)
                }
                Image(systemName: "pencil")
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(slot == nil || ink.isMarkingUp)
        .accessibilityLabel(steps.isEmpty ? "No sequence. Edit sequence" : "Sequence: \(steps.map(\.label).joined(separator: ", ")). Edit sequence")
    }

    /// "123" shows the Nashville numbers, "ABC" the chart as printed.
    private var chartToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { original in
                Button { showOriginal = original } label: {
                    Text(original ? "ABC" : "123")
                        .font(.subheadline.weight(.bold).monospaced())
                        .frame(width: 44, height: 32)
                        .background(showOriginal == original ? Theme.lime : Color.clear, in: Capsule())
                        .foregroundStyle(showOriginal == original ? Theme.green : Color.white)
                }
                .accessibilityLabel(original ? "Original chords" : "Nashville numbers")
                .accessibilityAddTraits(showOriginal == original ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func subtitle(for page: StandPage) -> String {
        var parts: [String] = []
        if !page.slot.key.isEmpty, page.slot.hasChart { parts.append("Key of \(page.slot.key)") }
        if page.pageCount > 1 { parts.append("page \(page.page + 1) of \(page.pageCount)") }
        if let nextSong { parts.append("Next: \(nextSong.title)") }
        return parts.joined(separator: " · ")
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(width: 48, height: 44)
        }
        .accessibilityLabel(label)
    }
}
