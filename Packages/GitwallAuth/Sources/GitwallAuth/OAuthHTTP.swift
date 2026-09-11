import Foundation

/// Form-encoded POSTs shared by the flows.
enum OAuthHTTP {
    static func formRequest(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Gitwall", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(encode(fields).utf8)
        return request
    }

    static func encode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// Decodes a JSON object body; tolerant of non-JSON error pages.
    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
