import Foundation
import GitwallCore
import Testing
@testable import GitwallGitHub

/// Checks the item-state lookup against GitHub itself: the open items a fetch just returned must all come back from
/// `nodes(ids:)` as open, with the kind they were fetched as. Up to 150 of them, half pull requests where there are
/// enough, so the lookup runs in two batches of ``GraphQLQueries/maxItemStateLookupsPerRequest``. Prints counts only.
///
///     GITWALL_GITHUB_TOKEN=$(gh auth token) swift test --package-path Packages/GitwallGitHub --filter ItemStateLiveTests
///
/// `GITWALL_GITHUB_REPO` picks the repositories as for ``PresetSearchQueryLiveTests``. With 100 open items or fewer the
/// lookup runs in one batch, and the test says so instead of failing.
@Suite("Item states against GitHub", .enabled(if: LiveGitHub.isEnabled))
struct ItemStateLiveTests {
    private static let sampleSize = 150

    @Test("items a fetch returned come back open, with their kind")
    func fetchedItemsAreOpen() async throws {
        let provider = GitHubProvider()
        let account = try await LiveGitHub.account(provider: provider)
        let items = try await provider.fetchItems(account: account, token: LiveGitHub.token, kinds: [.pullRequest, .issue])
        let sample = Self.sample(of: items.filter { $0.nodeID != nil })
        let batchSize = GraphQLQueries.maxItemStateLookupsPerRequest
        let batches = (sample.count + batchSize - 1) / batchSize
        #expect(!sample.isEmpty, "The repositories have no open items to look up")
        if sample.count <= batchSize {
            print("item state live | \(LiveGitHub.repositoryCount) | fewer than \(batchSize + 1) items, one batch only")
        }

        let start = ContinuousClock.now
        let states = try await provider.fetchItemStates(account: account, token: LiveGitHub.token, items: sample)
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18

        var open = 0, sameKind = 0, closed = 0, notFound = 0, unanswered = 0
        for item in sample {
            switch states[item.id] {
            case .open(let fresh)?:
                open += 1
                if fresh.kind == item.kind, fresh.id == item.id { sameKind += 1 }
            case .closed?, .merged?: closed += 1
            case .notFound?: notFound += 1
            case nil: unanswered += 1
            }
        }
        let pulls = sample.filter { $0.kind == .pullRequest }.count
        print("item state live | \(LiveGitHub.repositoryCount) | asked \(sample.count) (\(pulls) pull requests, \(sample.count - pulls) issues) "
            + "in \(batches) batches | open \(open), same kind \(sameKind) | closed or merged \(closed) | not found \(notFound) "
            + "| no answer \(unanswered) | lookup \(String(format: "%.1f", seconds)) s")
        #expect(open == sample.count, "\(sample.count - open) of \(sample.count) items did not come back open")
        #expect(sameKind == sample.count, "\(sample.count - sameKind) of \(sample.count) items came back as another item or kind")
    }

    /// Up to half pull requests, the rest issues, then whatever is left, in the order of the fetch.
    private static func sample(of items: [WorkItem]) -> [WorkItem] {
        let pulls = items.filter { $0.kind == .pullRequest }
        let issues = items.filter { $0.kind == .issue }
        var sample = Array(pulls.prefix(sampleSize / 2))
        sample += issues.prefix(sampleSize - sample.count)
        if sample.count < sampleSize {
            let taken = Set(sample.map(\.id))
            sample += items.filter { !taken.contains($0.id) }.prefix(sampleSize - sample.count)
        }
        return sample
    }
}
