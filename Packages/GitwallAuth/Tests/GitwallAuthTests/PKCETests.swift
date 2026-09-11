import Foundation
import GitwallAuth
import Testing

@Suite("PKCE")
struct PKCETests {
    @Test("challenge matches the RFC 7636 appendix B vector")
    func rfcVector() {
        // https://www.rfc-editor.org/rfc/rfc7636#appendix-B
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("verifier is 43 to 128 unreserved characters and unique per call")
    func verifierShape() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let first = PKCE.verifier()
        let second = PKCE.verifier()
        #expect((43...128).contains(first.count))
        #expect(first.allSatisfy { allowed.contains($0) })
        #expect(first != second)
    }

    @Test("state is URL-safe and unique")
    func state() {
        let a = PKCE.state()
        let b = PKCE.state()
        #expect(a.count >= 16)
        #expect(a != b)
        #expect(a.rangeOfCharacter(from: CharacterSet.urlQueryAllowed.inverted) == nil)
    }
}
