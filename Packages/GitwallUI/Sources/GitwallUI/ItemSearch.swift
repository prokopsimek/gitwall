import Foundation
import GitwallCore

/// Local, instant search used by the main window: every whitespace-separated word must match
/// the title, repository, `#number` or author login (case-insensitive).
public enum ItemSearch {
    public static func filter(_ items: [WorkItem], query: String) -> [WorkItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = [
                item.title.lowercased(),
                item.repoFullName.lowercased(),
                "#\(item.number)",
                item.author.login.lowercased(),
            ]
            return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
        }
    }
}
