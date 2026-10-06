import Foundation
import Observation
import OSLog

/// Loads the entries listed under an archive path and filters them by the search text.
///
/// Drives every archive list: the universities on the home screen (`path == .root`) and each
/// drill-down level below them.
@Observable
final class BrowseViewModel {
    let path: ArchivePath
    private(set) var state: Loadable<[ArchiveItem]> = .loading
    var searchText = ""

    @ObservationIgnored private let repository: any ArchiveRepository
    /// Set while a request is in flight, so a pull-to-refresh can't overlap the initial load.
    @ObservationIgnored private var isFetching = false

    private static let turkish = Locale(identifier: "tr_TR")

    init(path: ArchivePath, repository: any ArchiveRepository) {
        self.path = path
        self.repository = repository
    }

    /// The search text without surrounding whitespace.
    var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a search query is narrowing down the list.
    var isFiltering: Bool {
        !searchQuery.isEmpty
    }

    /// The loaded entries whose names match the search query; empty unless loaded.
    var visibleItems: [ArchiveItem] {
        guard let items = state.value else { return [] }
        let query = Self.searchKey(for: searchQuery)
        guard !query.isEmpty else { return items }
        return items.filter { Self.searchKey(for: $0.name).contains(query) }
    }

    /// Fetches the entries from scratch, showing the loading state meanwhile.
    func load() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        state = .loading
        do {
            state = .loaded(try await repository.items(at: path))
        } catch {
            // A cancelled load (the screen went away) stays `.loading`, so the next appearance retries.
            guard !Self.isCancellation(error) else { return }
            logFailure(error)
            state = .failed(message: error.userMessage)
        }
    }

    /// Re-fetches the entries while the current ones stay on screen (pull-to-refresh).
    ///
    /// A failed refresh keeps the items already shown; only an empty screen switches to the error state.
    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            state = .loaded(try await repository.items(at: path))
        } catch {
            guard !Self.isCancellation(error) else { return }
            logFailure(error)
            if state.value == nil {
                state = .failed(message: error.userMessage)
            }
        }
    }

    /// Re-reads the entries each time the archive changes, for as long as the calling task runs
    /// (the screen's lifetime). An initial load still in progress is left alone: it already returns
    /// the newest data the database holds.
    func refreshOnArchiveChanges() async {
        for await _ in repository.archiveChanges() where !state.isLoading {
            await refresh()
        }
    }

    // MARK: - Helpers

    /// Folds Turkish text for matching: case- and diacritic-insensitive, dotted and dotless i alike,
    /// so "kocaeli" finds "KOCAELİ", "dumlupinar" finds "DUMLUPINAR" and "isletme" finds "İŞLETME".
    ///
    /// Comparing with `range(of:options: [.caseInsensitive, .diacriticInsensitive], locale: tr_TR)` alone
    /// misses these: diacritic folding turns "İ" into "I", which Turkish casing then pairs with "ı", not "i".
    private static func searchKey(for text: String) -> String {
        text.lowercased(with: turkish)
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func logFailure(_ error: any Error) {
        let location = path.isRoot ? "root" : path.components.joined(separator: " › ")
        let reason = String(describing: error)
        Logger.archive.error("Loading \(location, privacy: .public) failed: \(reason, privacy: .public)")
    }
}
