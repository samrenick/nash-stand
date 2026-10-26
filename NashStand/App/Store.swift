import Foundation
import PencilKit

/// Everything on the iPad lives in Documents, so it works with no Mac in sight:
///   Setlists/<id>.json        downloaded setlists
///   Charts/<songId>.pdf       charts with Nashville numbers, as rendered on the Mac
///   Charts/<songId>.original.pdf   the same charts as printed, without numbers
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

    func originalURL(songId: String) -> URL { chartsDir.appendingPathComponent("\(songId).original.pdf") }

    /// The chart to show for a slot: the original when asked for and available, otherwise the numbered one.
    func chartURL(for slot: SharedSlot, original: Bool) -> URL {
        let url = originalURL(songId: slot.songId)
        return original && files.fileExists(atPath: url.path) ? url : chartURL(songId: slot.songId)
    }

    /// Saves a downloaded setlist. charts and originals map song IDs to freshly downloaded PDFs.
    func save(_ setlist: SharedSetlist, charts: [String: URL], originals: [String: URL] = [:]) throws {
        for (songId, downloaded) in charts {
            try replace(chartURL(songId: songId), with: downloaded)
            // A resend without an original shouldn't leave a stale one behind.
            if originals[songId] == nil { try? files.removeItem(at: originalURL(songId: songId)) }
        }
        for (songId, downloaded) in originals {
            try replace(originalURL(songId: songId), with: downloaded)
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
            try? files.removeItem(at: originalURL(songId: slot.songId))
        }
    }

    private func replace(_ destination: URL, with downloaded: URL) throws {
        try? files.removeItem(at: destination)
        try files.moveItem(at: downloaded, to: destination)
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
