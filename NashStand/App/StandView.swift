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

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !pages.isEmpty {
                PageReader(pages: pages, store: store, index: $index, ink: ink)
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
            #endif
            // A music stand shouldn't dim mid-song.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var current: StandPage? { pages.indices.contains(index) ? pages[index] : nil }

    private var nextSong: SharedSlot? {
        guard let current, current.page == current.pageCount - 1 else { return nil }
        return setlist.songs.indices.contains(current.slotIndex + 1) ? setlist.songs[current.slotIndex + 1] : nil
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Label("Setlists", systemImage: "chevron.left").font(.body.weight(.semibold))
            }
            .frame(minWidth: 110, alignment: .leading)

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
            .frame(minWidth: 110, alignment: .trailing)
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
            .frame(minWidth: 220, maxWidth: 360)
            .foregroundStyle(.white)
        }
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
