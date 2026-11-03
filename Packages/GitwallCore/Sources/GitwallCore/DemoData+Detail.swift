import Foundation

/// Sample Detail, so Detail can be shown without a network in sample data and in `--debug-demo`. Two items are worked
/// out in full: a pull request with a failing check, a review requested from me and an agent's plan in a
/// `<details>` block, and a P0 issue. Every other sample item gets a short description. Names are fictional.
extension DemoData {
    public static func detail(for item: WorkItem) -> ItemDetail? {
        guard item.accountID == github.id || item.accountID == gitlab.id else { return nil }
        switch (item.repoFullName, item.number) {
        case ("northwind/infra", 97): return armMigration(item)
        case ("northwind/storefront", 1287): return safariIssue(item)
        default: return summary(item)
        }
    }

    private static let author = (
        tomas: UserRef(login: "tomasn", displayName: "Tomas Novak"),
        ondrej: UserRef(login: "ondrej", displayName: "Ondrej Hruby"),
        jana: UserRef(login: "jana.v", displayName: "Jana Vesela"),
        mara: UserRef(login: "mara-k", displayName: "Mara Kovac"),
        agent: UserRef(login: "northwind-agent[bot]", displayName: "Northwind Agent")
    )

    private static func summary(_ item: WorkItem) -> ItemDetail {
        let body = item.kind == .pullRequest
            ? "## Summary\n\n\(item.title).\n\n- [x] Tests added\n- [ ] Docs updated"
            : "\(item.title).\n\nPart of the sample data: in a real account the whole description and conversation appear here."
        return ItemDetail(
            itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: item.updatedAt,
            body: .success(body),
            branches: .success(item.kind == .pullRequest ? Branches(head: "\(item.author.login)/change-\(item.number)", base: "main") : nil),
            timeline: .success([
                TimelineEvent(id: "\(item.id)-opened", kind: item.kind == .pullRequest ? .readyForReview : .commented,
                              actor: item.author, createdAt: item.createdAt),
            ])
        )
    }

    private static func armMigration(_ item: WorkItem) -> ItemDetail {
        let updated = item.updatedAt
        func ago(_ minutes: Double) -> Date { updated.addingTimeInterval(-minutes * 60) }
        let base = item.url.absoluteString
        let actions = "https://github.com/northwind/infra/actions/runs/9120443"

        let body = """
        Moves the staging cluster from x86 to ARM nodes. Same instance count, about 30 % cheaper per month.

        ## Changes

        - New node pool `staging-arm64` (Graviton, 3 × `m7g.large`)
        - Images built for `linux/arm64` next to `linux/amd64`
        - Old pool drained after the switch, removed in a follow-up

        ## Checklist

        - [x] Terraform plan reviewed
        - [x] Images published for both architectures
        - [ ] e2e green on arm64

        ```hcl
        node_pool "staging-arm64" {
          machine_type = "m7g.large"
          node_count   = 3
        }
        ```
        """

        let agentPlan = """
        I looked at the failing **e2e (arm64)** job: the Chromium layer in the test image is built for x86 only.

        <details>
        <summary>Plan (3 steps)</summary>

        1. Pin the base image to `node:22-bookworm-slim`, which ships arm64
        2. Rebuild the Chromium layer for both architectures
        3. Run `e2e (arm64)` again

        | Step | Status |
        |---|---|
        | Base image | done |
        | Chromium layer | in progress |
        | Run e2e again | waiting |

        </details>

        I'll push the fix to this branch once someone approves the plan.
        """

        let comments = [
            DetailComment(id: "c1", author: author.tomas, body: "@prokop @ondrej could you look at the node pool sizing?",
                          createdAt: ago(170), url: URL(string: "\(base)#issuecomment-1")),
            DetailComment(id: "c2", author: author.agent, body: agentPlan, createdAt: ago(40), url: URL(string: "\(base)#issuecomment-2")),
        ]
        let reviews = [
            DetailReview(id: "r1", author: author.ondrej, verdict: .commented,
                         body: "Sizing looks fine to me. The drain step should wait for the PodDisruptionBudgets.",
                         submittedAt: ago(90), url: URL(string: "\(base)#pullrequestreview-1")),
        ]
        let timeline = [
            TimelineEvent(id: "t1", kind: .committed(sha: "4f2a9c1", message: "Add ARM node pool for staging"), actor: author.tomas,
                          createdAt: ago(200), url: URL(string: "\(base)/commits/4f2a9c1")),
            TimelineEvent(id: "t2", kind: .labeled("infra"), actor: author.tomas, createdAt: ago(195)),
            TimelineEvent(id: "t3", kind: .reviewRequested(me.login), actor: author.tomas, createdAt: ago(180)),
            TimelineEvent(id: "t4", kind: .reviewRequested(author.ondrej.login), actor: author.tomas, createdAt: ago(180)),
            TimelineEvent(id: "t5", kind: .commented, actor: author.tomas, createdAt: ago(170), url: URL(string: "\(base)#issuecomment-1")),
            TimelineEvent(id: "t6", kind: .reviewed(.commented), actor: author.ondrej, createdAt: ago(90),
                          url: URL(string: "\(base)#pullrequestreview-1")),
            TimelineEvent(id: "t7", kind: .forcePushed(sha: "b81e07d"), actor: author.tomas, createdAt: ago(60)),
            TimelineEvent(id: "t8", kind: .commented, actor: author.agent, createdAt: ago(40), url: URL(string: "\(base)#issuecomment-2")),
        ]
        let passed = ["build (amd64)", "build (arm64)", "unit", "lint", "typecheck", "terraform fmt", "terraform validate",
                      "terraform plan (staging)", "docs", "security scan", "e2e (x64)"]
        var checks = passed.enumerated().map { index, name in
            DetailCheck(name: name, state: .passed, url: URL(string: "\(actions)/job/\(100 + index)"))
        }
        checks.insert(DetailCheck(name: "e2e (arm64)", state: .failed, url: URL(string: "\(actions)/job/99")), at: 4)
        checks.append(DetailCheck(name: "deploy preview", state: .skipped, url: nil))
        let files = [
            ChangedFile(path: "terraform/staging/node_pools.tf", additions: 64, deletions: 41),
            ChangedFile(path: "terraform/staging/variables.tf", additions: 12, deletions: 4),
            ChangedFile(path: ".github/workflows/images.yml", additions: 38, deletions: 9),
            ChangedFile(path: "docker/test-runner/Dockerfile", additions: 21, deletions: 17),
            ChangedFile(path: "k8s/staging/pdb.yaml", additions: 18, deletions: 0),
            ChangedFile(path: "docs/runbooks/staging-nodes.md", additions: 87, deletions: 162),
        ]
        return ItemDetail(
            itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: item.updatedAt,
            body: .success(body),
            branches: .success(Branches(head: "tomasn/staging-arm-nodes", base: "main")),
            comments: .success(comments), reviews: .success(reviews), timeline: .success(timeline),
            linkedItems: .success([
                LinkedItem(kind: .issue, repoFullName: "northwind/infra", number: 88, title: "Cut staging cost by a third",
                           url: URL(string: "https://github.com/northwind/infra/issues/88")!, state: .open),
            ]),
            checks: .success(checks),
            files: .success(ChangedFiles(files: files, totalCount: files.count))
        )
    }

    private static func safariIssue(_ item: WorkItem) -> ItemDetail {
        let updated = item.updatedAt
        func ago(_ minutes: Double) -> Date { updated.addingTimeInterval(-minutes * 60) }
        let base = item.url.absoluteString

        let body = """
        The **Pay now** button does nothing on Safari 18 when VoiceOver is on. Without VoiceOver it works.

        ## Steps to reproduce

        1. Turn VoiceOver on (⌘F5)
        2. Add anything to the cart and open checkout
        3. Move to **Pay now** and press Control-Option-Space

        ## Environment

        | Browser | VoiceOver | Result |
        |---|---|---|
        | Safari 18.1 | on | nothing happens |
        | Safari 18.1 | off | works |
        | Chrome 131 | on | works |
        """
        let comments = [
            DetailComment(id: "c1", author: author.mara, body: "Reproduced. The button is a `div` with a click handler, so VoiceOver never sends the click.",
                          createdAt: ago(300), url: URL(string: "\(base)#issuecomment-1")),
            DetailComment(id: "c2", author: me, body: "I'll take it. Swapping it for a real `button` should be enough.",
                          createdAt: ago(240), url: URL(string: "\(base)#issuecomment-2")),
            DetailComment(id: "c3", author: author.jana, body: "Thanks! Could the fix land in 2.4? Support has three tickets about it.",
                          createdAt: ago(0), url: URL(string: "\(base)#issuecomment-3")),
        ]
        let timeline = [
            TimelineEvent(id: "t1", kind: .labeled("bug"), actor: author.jana, createdAt: ago(320)),
            TimelineEvent(id: "t2", kind: .labeled("frontend"), actor: author.jana, createdAt: ago(320)),
            TimelineEvent(id: "t3", kind: .commented, actor: author.mara, createdAt: ago(300), url: URL(string: "\(base)#issuecomment-1")),
            TimelineEvent(id: "t4", kind: .assigned(me.login), actor: me, createdAt: ago(240)),
            TimelineEvent(id: "t5", kind: .commented, actor: me, createdAt: ago(240), url: URL(string: "\(base)#issuecomment-2")),
            TimelineEvent(id: "t6", kind: .commented, actor: author.jana, createdAt: ago(0), url: URL(string: "\(base)#issuecomment-3")),
        ]
        return ItemDetail(
            itemID: item.id, itemUpdatedAt: item.updatedAt, fetchedAt: item.updatedAt,
            body: .success(body), branches: .success(nil),
            comments: .success(comments), timeline: .success(timeline),
            linkedItems: .success([
                LinkedItem(kind: .pullRequest, repoFullName: "northwind/storefront", number: 1292,
                           title: "Checkout: make Pay now a real button",
                           url: URL(string: "https://github.com/northwind/storefront/pull/1292")!, state: .open),
            ])
        )
    }
}
