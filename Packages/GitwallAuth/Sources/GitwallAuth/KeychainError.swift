import Foundation
import Security

/// Failures raised by ``KeychainTokenStore``.
public enum KeychainError: Error, Equatable, LocalizedError {
    /// The Security framework returned a status this package does not translate.
    /// `-34018` (`errSecMissingEntitlement`) means the process lacks an
    /// application-identifier entitlement, which the data-protection keychain requires.
    case unhandled(OSStatus)
    /// The token could not be serialised to JSON.
    case encoding
    /// The item in the Keychain is not a valid JSON ``StoredToken``.
    case decoding

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown Security framework error"
            return "Keychain error \(status): \(message)"
        case .encoding:
            return "The token could not be encoded for the Keychain."
        case .decoding:
            return "The token stored in the Keychain could not be decoded."
        }
    }
}
