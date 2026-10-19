import Foundation
import Network

/// Finds Nash on the Mac with Bonjour (or a typed-in address) and lists the setlists it is sharing.
@MainActor
final class MacFinder: ObservableObject {
    @Published private(set) var macName: String?
    @Published private(set) var shared: [SharedSetlist] = []
    @Published private(set) var connected = false
    @Published private(set) var downloading: Set<String> = []
    @Published var error: String?
    @Published var manualAddress = UserDefaults.standard.string(forKey: "manualAddress") ?? "" {
        didSet {
            UserDefaults.standard.set(manualAddress, forKey: "manualAddress")
            restart()
        }
    }

    static let defaultPort = 8417

    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private var baseURL: URL?
    private var poll: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config)
    }()

    func start() {
        guard poll == nil else { return }
        restart()
        // Keep the list fresh while it's on screen, so a setlist sent from the Mac shows up by itself.
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        browser?.cancel()
        browser = nil
        resolver?.cancel()
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        baseURL = nil
        macName = nil
        connected = false
        shared = []
        let address = manualAddress.trimmingCharacters(in: .whitespaces)
        if !address.isEmpty {
            let hostPort = address.contains(":") ? address : "\(address):\(Self.defaultPort)"
            baseURL = URL(string: "http://\(hostPort)/")
            macName = address
            Task { await refresh() }
            return
        }
        let browser = NWBrowser(for: .bonjour(type: "_nash._tcp", domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard let result = results.first, case let .service(name, _, _, _) = result.endpoint else {
            macName = nil
            baseURL = nil
            connected = false
            shared = []
            return
        }
        macName = name
        resolve(result.endpoint)
    }

    /// Bonjour gives a service name; connecting briefly reveals the Mac's IP address and port.
    private func resolve(_ endpoint: NWEndpoint) {
        resolver?.cancel()
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                    Task { @MainActor in
                        self?.baseURL = URL(string: "http://\(address):\(port.rawValue)/")
                        await self?.refresh()
                    }
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
        resolver = connection
    }

    func refresh() async {
        guard let baseURL else { return }
        do {
            let (data, response) = try await session.data(from: baseURL.appendingPathComponent("api/setlists"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            shared = try JSONDecoder().decode([SharedSetlist].self, from: data)
            connected = true
        } catch {
            connected = false
        }
    }

    func download(_ setlist: SharedSetlist, into store: Store) async {
        guard let baseURL, !downloading.contains(setlist.id) else { return }
        downloading.insert(setlist.id)
        defer { downloading.remove(setlist.id) }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var charts: [String: URL] = [:]
            for slot in setlist.songs where slot.hasChart && charts[slot.songId] == nil {
                let url = baseURL.appendingPathComponent("api/setlists/\(setlist.id)/songs/\(slot.songId).pdf")
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
                let file = staging.appendingPathComponent("\(slot.songId).pdf")
                try data.write(to: file)
                charts[slot.songId] = file
            }
            try store.save(setlist, charts: charts)
        } catch {
            self.error = "Couldn’t download “\(setlist.title)”. Make sure Nash is open on the Mac, then try again."
        }
    }
}
