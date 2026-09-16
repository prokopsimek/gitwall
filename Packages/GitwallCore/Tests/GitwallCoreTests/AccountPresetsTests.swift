import Foundation
import Testing
@testable import GitwallCore

@Suite("Account presets")
struct AccountPresetsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let me = UserRef(login: "prokop")

    func github(login: String = "prokop") -> Account {
        Account(kind: .github, baseURL: URL(string: "https://github.com")!, displayName: "GitHub (\(login))", me: UserRef(login: login))
    }

    func gitlab(host: String = "git.applifting.cz") -> Account {
        Account(kind: .gitlab, baseURL: URL(string: "https://\(host)")!, displayName: "\(host) (prokop)", me: me)
    }

    // MARK: - Labels

    @Test("short labels name the host, and add the login only when a host repeats")
    func shortLabels() {
        let personal = github(login: "prokop")
        let work = github(login: "prokop-work")
        let selfHosted = gitlab()
        let cloud = Account(kind: .gitlab, baseURL: URL(string: "https://gitlab.com")!, displayName: "GitLab", me: me)

        #expect(personal.shortLabel(among: [personal, selfHosted]) == "GitHub")
        #expect(selfHosted.shortLabel(among: [personal, selfHosted]) == "git.applifting.cz")
        #expect(cloud.shortLabel(among: [cloud]) == "GitLab")
        #expect(personal.shortLabel(among: [personal, work]) == "GitHub (prokop)")
        #expect(work.shortLabel(among: [personal, work]) == "GitHub (prokop-work)")
    }

    // MARK: - The three presets

    @Test("an account gets assigned pull requests, assigned issues and reviews waiting, all scoped to it")
    func threePresets() {
        let account = github()
        let presets = Preset.accountDefaults(for: account, label: "GitHub", pullRequestTerm: "Pull request", showCountInMenuBar: false)

        #expect(presets.map(\.name) == ["GitHub · Assigned pull requests", "GitHub · Assigned issues", "GitHub · Waiting for my review"])
        #expect(presets.allSatisfy { $0.scopes == [PresetScope(accountID: account.id)] })
        #expect(presets[0].kinds == [.pullRequest] && presets[0].filter.relations == [.assignedToMe])
        #expect(presets[1].kinds == [.issue] && presets[1].filter.relations == [.assignedToMe])
        #expect(presets[2].kinds == [.pullRequest] && presets[2].filter.relations == [.reviewRequestedFromMe])
        #expect(presets[2].filter.includeDrafts == false)
        #expect(presets.allSatisfy { $0.notifications.isEmpty })
        #expect(presets.allSatisfy { !$0.showCountInMenuBar })
        #expect(Set(presets.map(\.id)).count == 3)
    }

    @Test("GitLab presets say merge requests, and the menu bar count goes to the review preset when asked")
    func gitLabTerms() {
        let presets = Preset.accountDefaults(for: gitlab(), label: "git.applifting.cz", pullRequestTerm: "Merge request", showCountInMenuBar: true)
        #expect(presets[0].name == "git.applifting.cz · Assigned merge requests")
        #expect(presets.map(\.showCountInMenuBar) == [false, false, true])
    }

    @Test("the only shared default is All open")
    func sharedDefaults() {
        let shared = Preset.defaults()
        #expect(shared.map(\.name) == ["All open"])
        #expect(shared[0].scopes.isEmpty)
        #expect(shared[0].kinds == [.pullRequest, .issue])
    }

    // MARK: - Adding accounts

    @Test("the first account brings All open plus its own three, marked as done")
    func firstAccount() {
        let account = github()
        let config = AppConfig().adding(account, pullRequestTerm: "Pull request")

        #expect(config.accounts.count == 1)
        #expect(config.accounts[0].defaultPresetsCreated == true)
        #expect(config.presets.map(\.name) == ["All open", "GitHub · Assigned pull requests", "GitHub · Assigned issues", "GitHub · Waiting for my review"])
        // Nothing showed a count before, so the new review preset takes it.
        #expect(config.presets.filter(\.showCountInMenuBar).map(\.name) == ["GitHub · Waiting for my review"])
    }

    @Test("a second account adds only its own three and leaves the menu bar count where it was")
    func secondAccount() {
        let first = AppConfig().adding(github(), pullRequestTerm: "Pull request")
        let config = first.adding(gitlab(), pullRequestTerm: "Merge request")

        #expect(config.presets.count == 7)
        #expect(config.presets.suffix(3).map(\.name) == ["git.applifting.cz · Assigned merge requests", "git.applifting.cz · Assigned issues", "git.applifting.cz · Waiting for my review"])
        #expect(config.presets.filter(\.showCountInMenuBar).count == 1)
        #expect(config.presets.first(where: \.showCountInMenuBar)?.name == "GitHub · Waiting for my review")
    }

    @Test("an existing configuration keeps its presets when an account is added")
    func keepsExistingPresets() {
        let custom = Preset(name: "Prdel", kinds: [.pullRequest])
        let config = AppConfig(presets: [custom]).adding(github(), pullRequestTerm: "Pull request")
        #expect(config.presets.first?.name == "Prdel")
        #expect(!config.presets.contains { $0.name == "All open" }, "All open is only for a configuration without presets")
        #expect(config.presets.count == 4)
    }

    // MARK: - One-time seeding of older accounts

    @Test("accounts from before per-account presets get them once; a second pass changes nothing")
    func seeding() {
        var old = github()
        old.defaultPresetsCreated = nil
        var alsoOld = gitlab()
        alsoOld.defaultPresetsCreated = false
        let existing = Preset(name: "My issues", kinds: [.issue])
        let start = AppConfig(accounts: [old, alsoOld], presets: [existing])

        let seeded = start.seedingDefaultPresets { $0 == .gitlab ? "Merge request" : "Pull request" }
        #expect(seeded.presets.count == 7)
        #expect(seeded.presets.first?.name == "My issues")
        #expect(seeded.accounts.allSatisfy { $0.defaultPresetsCreated == true })

        let again = seeded.seedingDefaultPresets { _ in "Pull request" }
        #expect(again == seeded)
    }

    @Test("deleted presets stay deleted: a seeded account is not seeded again")
    func seedingRespectsDeletion() {
        let seeded = AppConfig().adding(github(), pullRequestTerm: "Pull request")
        var trimmed = seeded
        trimmed.presets.removeAll { $0.name.contains("Assigned issues") }
        #expect(trimmed.seedingDefaultPresets { _ in "Pull request" } == trimmed)
    }

    // MARK: - Manual "Add Default Presets"

    @Test("adding the defaults by hand fills in only what is missing")
    func manualAdd() {
        let account = github()
        let seeded = AppConfig().adding(account, pullRequestTerm: "Pull request")
        #expect(seeded.addingDefaultPresets(for: account.id, pullRequestTerm: "Pull request") == seeded)

        var trimmed = seeded
        trimmed.presets.removeAll { $0.name == "GitHub · Assigned issues" }
        let refilled = trimmed.addingDefaultPresets(for: account.id, pullRequestTerm: "Pull request")
        #expect(refilled.presets.count == seeded.presets.count)
        #expect(refilled.presets.contains { $0.name == "GitHub · Assigned issues" })

        // A renamed preset with the same filter still counts as present.
        var renamed = seeded
        if let index = renamed.presets.firstIndex(where: { $0.name == "GitHub · Assigned pull requests" }) {
            renamed.presets[index].name = "My GitHub PRs"
        }
        #expect(renamed.addingDefaultPresets(for: account.id, pullRequestTerm: "Pull request").presets.count == seeded.presets.count)
    }

    // MARK: - Removing accounts

    @Test("removing an account deletes its own presets and narrows the ones it shared")
    func removing() {
        let a = github()
        let b = gitlab()
        var config = AppConfig().adding(a, pullRequestTerm: "Pull request").adding(b, pullRequestTerm: "Merge request")
        let shared = Preset(name: "Both", scopes: [PresetScope(accountID: a.id), PresetScope(accountID: b.id)], kinds: [.pullRequest])
        config.presets.append(shared)

        let removed = config.removing(accountID: b.id)

        #expect(removed.accounts.map(\.id) == [a.id])
        #expect(!removed.presets.contains { $0.name.hasPrefix("git.applifting.cz") })
        #expect(removed.presets.contains { $0.name == "All open" }, "presets for every account are not tied to one")
        #expect(removed.presets.first { $0.name == "Both" }?.scopes == [PresetScope(accountID: a.id)])
        // Nothing may silently widen to "all accounts".
        #expect(removed.presets.filter { $0.scopes.isEmpty }.map(\.name) == ["All open"])
    }

    // MARK: - The presets actually select the right items

    @Test("each account's presets see only that account, and the review preset keeps drafts that ask for my review")
    func filtering() {
        let a = github()
        let b = gitlab()
        let config = AppConfig().adding(a, pullRequestTerm: "Pull request").adding(b, pullRequestTerm: "Merge request")

        func item(_ n: Int, _ account: Account, _ kind: ItemKind, assigned: Bool = false, review: Bool = false, draft: Bool = false) -> WorkItem {
            WorkItem(accountID: account.id, kind: kind, repoFullName: "acme/app", number: n, title: "#\(n)",
                     url: URL(string: "https://example.com/\(n)")!, author: UserRef(login: "someone"), createdAt: now, updatedAt: now,
                     isDraft: draft, assignees: assigned ? [me] : [], requestedReviewers: review ? [me] : [])
        }
        let items = [
            item(1, a, .pullRequest, assigned: true),
            item(2, a, .issue, assigned: true),
            item(3, a, .pullRequest, review: true),
            item(4, a, .pullRequest, review: true, draft: true),
            item(5, b, .pullRequest, assigned: true),
            item(6, b, .issue, assigned: true),
            item(7, a, .pullRequest),
            item(8, a, .pullRequest, draft: true),
        ]
        func numbers(_ name: String) -> [Int] {
            let preset = config.presets.first { $0.name == name }!
            return FilterEngine.items(matching: preset, in: items, accounts: config.accounts, now: now).map(\.number).sorted()
        }

        #expect(numbers("GitHub · Assigned pull requests") == [1])
        #expect(numbers("GitHub · Assigned issues") == [2])
        // 4 is a draft that names me as a reviewer, the way cloud agents file their pull requests; 8 is an
        // ordinary draft nobody asked me to look at.
        #expect(numbers("GitHub · Waiting for my review") == [3, 4])
        #expect(numbers("git.applifting.cz · Assigned merge requests") == [5])
        #expect(numbers("git.applifting.cz · Assigned issues") == [6])
        #expect(numbers("All open") == [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
