import Foundation
import GitwallAuth
import GitwallCore
@testable import Gitwall
import Testing

/// Detail in a window, with sample data so nothing touches the network, the App Group or the Keychain.
@Suite("Detail model")
@MainActor
struct DetailModelTests {
    private let sandbox = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gitwall-detail-\(UUID().uuidString)")

    private func sampleEnvironment() -> AppEnvironment {
        let environment = AppEnvironment(
            defaults: UserDefaults(suiteName: "gitwall.tests.\(UUID().uuidString)")!,
            tokenStore: InMemoryTokenStore(),
            sandbox: sandbox
        )
        environment.start()
        environment.enterSampleData()
        return environment
    }

    private func item(_ environment: AppEnvironment, _ repo: String, _ number: Int) throws -> WorkItem {
        try #require(environment.snapshot?.items.first { $0.repoFullName == repo && $0.number == number })
    }

    /// Waits for the debounce and the load, at most two seconds.
    private func loaded(_ model: DetailModel) async throws -> ItemDetail {
        for _ in 0..<40 {
            if case .loaded(let detail)? = model.selectedRemote { return detail }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    @Test("a click selects, shows Detail and loads the item's detail after the debounce")
    func showLoads() async throws {
        let environment = sampleEnvironment()
        let model = DetailModel(environment: environment)
        let pull = try item(environment, "northwind/infra", 97)

        model.show(pull.id)

        #expect(model.isPresented)
        #expect(model.selectedItem == pull)
        #expect(model.selectedRemote == nil, "the provider is asked only after the selection rests")
        let detail = try await loaded(model)
        #expect(detail == DemoData.detail(for: pull))
        let content = model.content(for: pull, preset: environment.config.presets[2])
        #expect(content.nextStep.action == .reviewChanges)
        #expect(content.reasons.contains(.reviewRequestedFromMe))
        #expect(content.hostName == "GitHub")
        #expect(content.whatsNew.count == WhatsNew.firstOpenCount)
    }

    @Test("opening marks the item seen in memory only while sample data is on")
    func sampleSeenStaysInMemory() async throws {
        let environment = sampleEnvironment()
        let model = DetailModel(environment: environment)
        let issue = try item(environment, "northwind/storefront", 1287)

        model.show(issue.id)
        _ = try await loaded(model)

        #expect(environment.details.lastSeen(issue.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(SeenStore.fileName).path))
    }

    @Test("arrows move through the visible items and stop at the ends")
    func arrows() throws {
        let environment = sampleEnvironment()
        let model = DetailModel(environment: environment)
        let ids = Array((environment.snapshot?.items ?? []).prefix(3).map(\.id))
        model.visibleItemIDs = ids

        model.move(by: 1)
        #expect(model.selectedItemID == ids[0])
        model.move(by: 1)
        model.move(by: 1)
        model.move(by: 1)
        #expect(model.selectedItemID == ids[2])
        model.move(by: -5)
        #expect(model.selectedItemID == ids[0])
        #expect(!model.isPresented, "moving the selection alone does not open the panel")
    }

    @Test("Show Detail without a selection takes the first item; Close and Toggle hide it")
    func presentAndClose() throws {
        let environment = sampleEnvironment()
        let model = DetailModel(environment: environment)
        let ids = Array((environment.snapshot?.items ?? []).prefix(2).map(\.id))
        model.visibleItemIDs = ids

        model.present()
        #expect(model.isPresented)
        #expect(model.selectedItemID == ids[0])
        model.close()
        #expect(!model.isPresented)
        model.toggle()
        #expect(model.isPresented)
        model.toggle()
        #expect(!model.isPresented)
    }

    @Test("a new selection never shows the previous item's detail")
    func noStaleDetail() async throws {
        let environment = sampleEnvironment()
        let model = DetailModel(environment: environment)
        let pull = try item(environment, "northwind/infra", 97)
        let issue = try item(environment, "northwind/storefront", 1287)

        model.show(pull.id)
        _ = try await loaded(model)
        model.select(issue.id)

        #expect(model.selectedRemote == nil || model.selectedRemote == .loaded(DemoData.detail(for: issue)!))
        let detail = try await loaded(model)
        #expect(detail.itemID == issue.id)
    }
}
