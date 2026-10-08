import Foundation

public enum ScreenshotRule {
    /// Screenshots older than `days`, oldest first. Favorites and undated items are never candidates.
    public static func candidates(_ items: [MediaItem], olderThan days: Int = 30, now: Date) -> [MediaID] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items
            .filter { $0.kind == .screenshot && !$0.isFavorite && ($0.creationDate.map { $0 <= cutoff } ?? false) }
            .sorted { ($0.creationDate!, $0.id) < ($1.creationDate!, $1.id) }
            .map(\.id)
    }
}
