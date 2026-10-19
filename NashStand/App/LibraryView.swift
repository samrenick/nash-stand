import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var finder = MacFinder()
    @State private var playing: SharedSetlist?
    @State private var editingAddress = false

    var body: some View {
        NavigationStack {
            List {
                macSection
                if store.setlists.isEmpty {
                    Section {
                        Text("No setlists on this iPad yet. Send one from Nash on your Mac and download it above.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                if !store.upcoming.isEmpty {
                    Section("Upcoming") { localRows(store.upcoming) }
                }
                if !store.past.isEmpty {
                    Section("Past") { localRows(store.past) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.cream.ignoresSafeArea())
            .navigationTitle("Nash Stand")
            .refreshable { await finder.refresh() }
        }
        .fullScreenCover(item: $playing) { StandView(setlist: $0) }
        .sheet(isPresented: $editingAddress) { AddressSheet(address: $finder.manualAddress) }
        .alert("Download failed", isPresented: Binding(get: { finder.error != nil }, set: { if !$0 { finder.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(finder.error ?? "")
        }
        .onAppear { finder.start() }
        #if DEBUG
        // Screenshot hook: `-autoplay N` downloads and opens the Nth shared setlist.
        .onChange(of: finder.shared) { _, shared in
            let args = ProcessInfo.processInfo.arguments
            guard playing == nil, let flag = args.firstIndex(of: "-autoplay"), args.indices.contains(flag + 1),
                  let n = Int(args[flag + 1]), shared.indices.contains(n) else { return }
            Task {
                if store.local(shared[n].id) == nil { await finder.download(shared[n], into: store) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                playing = store.local(shared[n].id)
            }
        }
        #endif
        .onDisappear { finder.stop() }
    }

    @ViewBuilder private var macSection: some View {
        Section {
            if !finder.connected {
                HStack(spacing: 14) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(finder.macName.map { "Connecting to \($0)…" } ?? "Looking for Nash on your Mac…")
                        Text("Open Nash on the Mac. Both need to be on the same wifi.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            } else if finder.shared.isEmpty {
                Text("Connected. In Nash on the Mac, open a setlist and click **Send to iPad**.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(finder.shared) { setlist in
                HStack {
                    SetlistLabel(setlist: setlist)
                    Spacer()
                    downloadButton(setlist)
                }
            }
        } header: {
            Text("From your Mac")
        } footer: {
            HStack(spacing: 4) {
                if finder.connected, let name = finder.macName { Text("Connected to \(name).") }
                Button(finder.manualAddress.isEmpty ? "Can’t find your Mac?" : "Change address") { editingAddress = true }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder private func downloadButton(_ setlist: SharedSetlist) -> some View {
        let local = store.local(setlist.id)
        if finder.downloading.contains(setlist.id) {
            ProgressView().frame(width: 110)
        } else if local?.sharedAt == setlist.sharedAt {
            Label("On iPad", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.green)
                .font(.subheadline.weight(.semibold))
        } else {
            Button {
                Task { await finder.download(setlist, into: store) }
            } label: {
                Text(local == nil ? "Download" : "Update")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.green)
        }
    }

    private func localRows(_ setlists: [SharedSetlist]) -> some View {
        ForEach(setlists) { setlist in
            Button { playing = setlist } label: {
                HStack {
                    SetlistLabel(setlist: setlist)
                    Spacer()
                    Image(systemName: "play.fill").foregroundStyle(Theme.green)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions {
                Button("Remove", role: .destructive) { store.delete(setlist) }
            }
        }
    }
}

private struct SetlistLabel: View {
    let setlist: SharedSetlist

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(Theme.green)
                .frame(width: 40, height: 40)
                .background(Theme.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(setlist.formattedDate).font(.headline)
                Text("\(setlist.title) · \(setlist.songSummary)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AddressSheet: View {
    @Binding var address: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.20:8417", text: $draft)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Nash on the Mac shows this address at the bottom of each setlist. Leave it empty to find the Mac automatically.")
                }
            }
            .navigationTitle("Mac address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { address = draft; dismiss() }
                }
            }
        }
        .onAppear { draft = address }
    }
}
