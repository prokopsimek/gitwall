import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

@Suite("Project priorities: what is logged")
struct ProjectPriorityLogTests {
    @Test("a thrown error is logged by its kind, never by its message")
    func unavailableByKind() {
        let line = ProjectPriorityLog.unavailable(ProviderError.server(status: 502, message: "secret-org gateway says no"), items: 7)

        #expect(line.contains("server 502"))
        #expect(line.contains("7"))
        #expect(!line.contains("secret-org"))
        #expect(!line.contains("gateway says no"))
    }

    @Test("an error that is no ProviderError is logged by its type")
    func unavailableByType() {
        struct Odd: Error, LocalizedError { var errorDescription: String? { "secret-org text" } }

        let line = ProjectPriorityLog.unavailable(Odd(), items: 1)

        #expect(line.contains("Odd"))
        #expect(!line.contains("secret-org"))
    }

    @Test("every case of ProviderError has a kind without its message")
    func kinds() {
        #expect(ProjectPriorityLog.kind(of: ProviderError.unauthorized) == "unauthorized")
        #expect(ProjectPriorityLog.kind(of: ProviderError.rateLimited(resetAt: nil)) == "rateLimited")
        #expect(ProjectPriorityLog.kind(of: ProviderError.network("secret-org")) == "network")
        #expect(ProjectPriorityLog.kind(of: ProviderError.invalidResponse("secret-org")) == "invalidResponse")
        #expect(ProjectPriorityLog.kind(of: ProviderError.notFound("secret-org")) == "notFound")
        #expect(ProjectPriorityLog.kind(of: ProviderError.unsupported("secret-org")) == "unsupported")
    }

    @Test("skipped and refused lines name no account")
    func noAccountName() {
        #expect(!ProjectPriorityLog.skipped.contains("secret-account"))
        #expect(!ProjectPriorityLog.refused.isEmpty)
    }
}

@Suite("Item states: what is logged")
struct ItemStateLogTests {
    private func errors(_ json: String) throws -> [GraphQLError] {
        try JSONDecoder().decode([GraphQLError].self, from: Data(json.utf8))
    }

    @Test("a FORBIDDEN error beside data is logged by count and type, never by its text")
    func forbiddenIsLogged() throws {
        let line = ItemStateLog.unexpected(try errors(
            #"[{"type":"FORBIDDEN","message":"The 'secret-org' organization forbids access via a personal access token"}]"#
        ))

        let text = try #require(line)
        #expect(text.contains("1"))
        #expect(text.contains("FORBIDDEN"))
        #expect(!text.contains("secret-org"))
    }

    @Test("NOT_FOUND alone is not logged; mixed with another type only the others count")
    func notFoundIsSilent() throws {
        #expect(ItemStateLog.unexpected(try errors(#"[{"type":"NOT_FOUND","message":"x"}]"#)) == nil)
        #expect(ItemStateLog.unexpected([]) == nil)

        let mixed = try #require(ItemStateLog.unexpected(try errors(
            #"[{"type":"NOT_FOUND","message":"x"},{"type":"FORBIDDEN","message":"y"},{"type":"INTERNAL","message":"z"}]"#
        )))
        #expect(mixed.contains("2"))
        #expect(mixed.contains("FORBIDDEN"))
        #expect(mixed.contains("INTERNAL"))
        #expect(!mixed.contains("NOT_FOUND"))
    }
}
