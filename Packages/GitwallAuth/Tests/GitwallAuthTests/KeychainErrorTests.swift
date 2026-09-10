import Foundation
import Security
import Testing
@testable import GitwallAuth

@Suite("KeychainError")
struct KeychainErrorTests {
    @Test("is Equatable")
    func equatable() {
        #expect(KeychainError.unhandled(errSecDuplicateItem) == .unhandled(errSecDuplicateItem))
        #expect(KeychainError.unhandled(errSecDuplicateItem) != .unhandled(errSecItemNotFound))
        #expect(KeychainError.encoding == .encoding)
        #expect(KeychainError.decoding == .decoding)
        #expect(KeychainError.encoding != .decoding)
    }

    @Test("unhandled description includes the status and the Security framework message")
    func unhandledDescription() throws {
        let error = KeychainError.unhandled(errSecMissingEntitlement)
        let description = try #require(error.errorDescription)
        #expect(description.contains("\(errSecMissingEntitlement)"))
        let expected = try #require(SecCopyErrorMessageString(errSecMissingEntitlement, nil) as String?)
        #expect(description.contains(expected))
    }

    @Test("encoding and decoding have non-empty descriptions")
    func codingDescriptions() throws {
        #expect(try #require(KeychainError.encoding.errorDescription).isEmpty == false)
        #expect(try #require(KeychainError.decoding.errorDescription).isEmpty == false)
        #expect(KeychainError.encoding.errorDescription != KeychainError.decoding.errorDescription)
    }

    @Test("localizedDescription goes through LocalizedError")
    func localizedDescription() {
        let error: any Error = KeychainError.decoding
        #expect(error.localizedDescription == KeychainError.decoding.errorDescription)
    }
}
