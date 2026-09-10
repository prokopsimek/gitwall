import Foundation

/// Parses RFC 8288 `Link` headers as sent by the GitHub REST API.
enum LinkHeader {
    static func nextURL(in header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments[0].hasPrefix("<"), segments[0].hasSuffix(">") else { continue }
            let isNext = segments.dropFirst().contains { segment in
                let normalized = segment.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "")
                return normalized.lowercased() == "rel=next"
            }
            guard isNext else { continue }
            let urlString = String(segments[0].dropFirst().dropLast())
            return URL(string: urlString)
        }
        return nil
    }
}
