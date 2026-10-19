import Foundation
import PencilKit

/// Everything on the iPad lives in Documents, so it works with no Mac in sight:
///   Setlists/<id>.json        downloaded setlists
///   Charts/<songId>.pdf       charts with Nashville numbers, as rendered on the Mac
///   Ink/<songId>/<page>.ink   handwriting, kept per song so it follows a chart into every setlist
@MainActor
final class Store: ObservableObject {
    @Published private(set) var setlists: [SharedSetlist] = []

    private let files = FileManager.default
    private let setlistsDir: URL
    private let chartsDir: URL
    private let inkDir: URL

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        setlistsDir = root.appendingPathComponent("Setlists", isDirectory: true)
        chartsDir = root.appendingPathComponent("Charts", isDirectory: true)
        inkDir = root.appendingPathComponent("Ink", isDirectory: true)
        for dir in [setlistsDir, chartsDir, inkDir] {
            try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
    }

    var upcoming: [SharedSetlist] { setlists.filter { !$0.isPast } }
    var past: [SharedSetlist] { setlists.filter(\.isPast).reversed() }

    func local(_ id: String) -> SharedSetlist? { setlists.first { $0.id == id } }

    func chartURL(songId: String) -> URL { chartsDir.appendingPathComponent("\(songId).pdf") }

    /// Saves a downloaded setlist. charts maps song IDs to freshly downloaded PDFs.
    func save(_ setlist: SharedSetlist, charts: [String: URL]) throws {
        for (songId, downloaded) in charts {
            let destination = chartURL(songId: songId)
            try? files.removeItem(at: destination)
            try files.moveItem(at: downloaded, to: destination)
        }
        try JSONEncoder().encode(setlist).write(to: manifestURL(setlist.id), options: .atomic)
        reload()
    }

    /// Removes a setlist and any charts no other setlist uses. Handwriting stays, in case the song comes back.
    func delete(_ setlist: SharedSetlist) {
        try? files.removeItem(at: manifestURL(setlist.id))
        reload()
        let inUse = Set(setlists.flatMap { $0.songs.map(\.songId) })
        for slot in setlist.songs where slot.hasChart && !inUse.contains(slot.songId) {
            try? files.removeItem(at: chartURL(songId: slot.songId))
        }
    }

    func ink(songId: String, page: Int) -> PKDrawing {
        guard let data = try? Data(contentsOf: inkURL(songId: songId, page: page)) else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    func saveInk(_ drawing: PKDrawing, songId: String, page: Int) {
        let url = inkURL(songId: songId, page: page)
        if drawing.strokes.isEmpty {
            try? files.removeItem(at: url)
            return
        }
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    private func reload() {
        let urls = (try? files.contentsOfDirectory(at: setlistsDir, includingPropertiesForKeys: nil)) ?? []
        setlists = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SharedSetlist.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
    }

    private func manifestURL(_ id: String) -> URL { setlistsDir.appendingPathComponent("\(id).json") }

    private func inkURL(songId: String, page: Int) -> URL {
        inkDir.appendingPathComponent(songId, isDirectory: true).appendingPathComponent("\(page).ink")
    }
}
