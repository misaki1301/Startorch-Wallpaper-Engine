import Foundation

/// Loads the gallery manifest: the last downloaded copy if there is one, otherwise the copy
/// bundled with the app. `refresh()` fetches the hosted manifest and caches it.
final class CatalogService {
    static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/misaki1301/Startorch-Wallpaper-Engine/main/catalog/catalog.json"
    )!

    private let remoteURL: URL
    private let cacheURL: URL
    private let bundledURL: URL?
    private let session: URLSession

    init(
        remoteURL: URL = CatalogService.defaultRemoteURL,
        cacheURL: URL = URL.cachesDirectory.appending(path: "catalog.json"),
        bundledURL: URL? = Bundle.main.url(forResource: "catalog", withExtension: "json"),
        session: URLSession = .shared
    ) {
        self.remoteURL = remoteURL
        self.cacheURL = cacheURL
        self.bundledURL = bundledURL
        self.session = session
    }

    func load() -> Catalog {
        for url in [cacheURL, bundledURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let catalog = try? Self.decode(data) {
                return catalog
            }
        }
        return .empty
    }

    func refresh() async throws -> Catalog {
        let (data, response) = try await session.data(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let catalog = try Self.decode(data)
        try data.write(to: cacheURL, options: .atomic)
        return catalog
    }

    static func decode(_ data: Data) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: data)
    }
}
