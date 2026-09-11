import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636) helpers for the GitLab authorization-code flow.
public enum PKCE {
    /// A fresh `code_verifier`: 64 unreserved characters from a cryptographic random source.
    public static func verifier() -> String {
        // RFC 7636 §4.1: 43–128 characters from [A-Za-z0-9-._~]. Base64url of 48 random bytes is 64 characters.
        base64URL(randomBytes(48))
    }

    /// `code_challenge` for `verifier` using the S256 method: base64url(SHA-256(verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// An opaque `state` value that ties the callback to the request that started it.
    public static func state() -> String {
        base64URL(randomBytes(24))
    }

    // MARK: - Private

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with \(status)")
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
