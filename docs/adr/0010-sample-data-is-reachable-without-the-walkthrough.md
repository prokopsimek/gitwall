# 10. Sample data is reachable without the walkthrough

Date: 2026-09-18

## Context

App Review rejected Gitwall twice under guideline 2.1(a). 0.4.1 was rejected on 2026-09-15 because every screen
is empty until someone pastes a token, and the notes asking the reviewer to create one were not enough. 0.5.1
(build 12) added sample data mode and was rejected again on 2026-09-17: "We are still unable to successfully
access part of the app."

The screenshot Apple attached shows Settings › Accounts with the "Welcome to Gitwall" block, an empty list and
one button, "Add Account…". Sample data was offered only on the walkthrough's account step
(`OnboardingView`), and the walkthrough only opens when `needsOnboarding && !onboardingCompleted`
(`AppDelegate.applicationDidFinishLaunching`). `onboardingCompleted` lives in the App Group, and the same
machine had reviewed 0.4.1 three days earlier, so the walkthrough never came back. The empty states in the
popover and the main window pointed at Settings › Accounts, which had no way in either. The only way back was
Settings › General › "Reset All Data…".

## Decision

Sample data is offered by `SampleDataOffer` (`Gitwall/Shared/SampleDataOffer.swift`) on **every** screen that is
empty for lack of an account: the walkthrough, Settings › Accounts, the Add Account sheet, the empty popover and
main window, and Help › Look Around with Sample Data. `AppEnvironment.canShowSampleData` stays the single
condition, so the offer still cannot stand in front of a real queue.

A demonstration mode also has to behave like a working installation, or a reviewer reads it as a broken app:

- Refresh brings in another review request (`DemoData.snapshot(now:arrivals:)`) and routes it through the usual
  `SnapshotDiff` path, so notifications can be tried out.
- Settings › Repositories lists `DemoData.discovery` instead of "No token stored for this account."
- Clicking an item explains that it is sample data, rather than opening a fictional URL that 404s.
- Widgets without an account offer the sample presets in "Edit Widget" and honour the chosen one.
- Adding a real account ends sample mode first, so the account is saved instead of living in memory next to
  fictional ones while its token sits in the Keychain.

## Consequences

- One more place to keep in mind when a new empty state is added; the rule is in `Gitwall/AGENTS.md`.
- `DemoData` is now part of the product, not only of the screenshot tooling. Its arrivals, repositories and
  preset ids are covered by tests in `GitwallCoreTests/DemoDataTests.swift`.
- The review notes and the demo recording (`docs/RELEASING.md`) describe the same paths. If an entry point is
  renamed, both change with it.
- Sample mode is still in-memory only: nothing reaches the App Group, the Keychain or the network.
