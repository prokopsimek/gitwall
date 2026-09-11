# Gitwall – plán (schváleno 2026-09-10)

## Stav k 2026-09-11

- Hotovo: M0, M1 (GitHub PAT end-to-end včetně GHES), M2 (GitLab cloud i self-managed, ověřeno proti
  git.applifting.cz 19.3), M3 (filtry, notifikace, onboarding), M4 (OAuth device flow pro GitHub, PKCE pro
  GitLab, tichá obnova tokenů), z M5 App Store Connect záznam, metadata, sedm screenshotů, privacy policy na
  GitHub Pages, verze 0.1.0 build 4 odeslaná do App Review 2026-09-10.
- Odchylky od plánu: App Group používá Team-ID formát, Keychain klasické úložiště, Dock ikona zapnutá,
  GitLab klient posílá token jako Bearer (funguje pro PAT i OAuth). Zdůvodnění v `docs/adr/`.
- 2026-09-11: Developer ID certifikát založený v portálu (API ho odmítá), notarizovaný build 0.2.0 (7) na
  GitHub Releases, build 7 nahraný do App Store Connect.
- 2026-09-11: 0.3.0 (8) – každý účet dostane tři výchozí presety (přiřazené PR/MR, přiřazené issues, čeká na
  můj review), stávající účty jednou automaticky; ze společných zůstal jen „All open“. Oprava GitLab review stavů
  a mazání presetů při odebrání účtu. README se screenshoty.
- Zbývá: po schválení 0.1.0 založit v App Store Connect rovnou verzi 0.3.0 s buildem 8 (0.2.0 se v obchodě
  přeskočí) a odeslat ji, do docs a README doplnit odkaz na App Store.
- Známé omezení: GitHub žádosti o review adresované týmu se do „Waiting for my review“ nepromítnou.
- SSH klíče nelze použít místo tokenu: metadata PR/issues (review, CI, štítky) poskytuje jen HTTP API.

## Context

Cíl: bezplatná nativní macOS aplikace, která agreguje pull requesty (merge requesty) a issues z více repozitářů napříč GitHub a GitLab (cloud i self-host) a ukazuje je na ploše ve WidgetKit widgetech a v menu bar popoveru. Kliknutí otevře detail v prohlížeči. Položky jsou řazené od nejnovější aktivity a nesou stav (review, CI, draft, konflikt). Publikace do Mac App Store, kód veřejný pod MIT.

Cílová skupina: vývojáři, členové IT týmů, tech/team leadi a manažeři. Lead chce přehled týmu, vývojář chce „čeká na můj review“.

Repozitář je prázdný (žádné commity). Rozhodnutí níže vzešla z rozhovoru (`/grill-me`).

## Rozhodnutí (shrnutí rozhovoru)

| Oblast | Rozhodnutí |
|---|---|
| Stack | Swift 6 / SwiftUI, WidgetKit extension, AppKit jen pro NSStatusItem; min. macOS 14 |
| Název | **Gitwall**; bundle `cz.prokopsimek.gitwall`, App Group `ZHU9NYW7PP.cz.prokopsimek.gitwall` (Team-ID style; see AppGroup.swift for why), URL schéma `gitwall://` |
| Účet Apple | osobní tým Prokop Simek (identity Development i Distribution jsou v Keychainu) |
| Data | tray app stahuje, widget jen čte snapshot z App Group; JSON soubory + Keychain na tokeny |
| Rozsah dat | všechny otevřené PR/issues z vybraných rep; filtry se aplikují lokálně |
| Konfigurace widgetu | pojmenované **pohledy (presety)** definované v app; widget si vybere pohled; libovolná kombinace PR + issues z více rep a účtů |
| Filtry | jednotný model (typ, stav, vztah ke mně, draft, štítky, review, CI, stáří, milestone, text) + volitelný nativní dotaz per účet |
| API | GraphQL pro seznamy (GitHub i GitLab), REST pro ověření tokenu, discovery rep a OAuth |
| Auth | PAT všude; GitHub.com device flow; GitLab.com Authorization Code + PKCE; self-host PAT nebo vlastní client ID |
| Výběr rep | discovery ze seznamu + celá org/skupina jako dynamický zdroj + ruční zápis |
| Obnova | interval v nastavení (1/2/5/15/30 min, výchozí 5), ruční obnova v tray i widgetu, ETag |
| Proces | menu bar agent; Dock ikona přepínatelná; spouštění při přihlášení přes SMAppService |
| Tray | levý klik popover (přepínač pohledů + seznam), volitelný počet u ikony, pravý klik menu (Obnovit, Nastavení, Spouštět při přihlášení, O aplikaci, Ukončit) |
| Widget | 4 velikosti; klik na řádek otevře PR přes `gitwall://item/…`; hlavička otevře popover; tlačítko obnovy |
| Stav PR | řádek: název, repo, číslo, avatar, čas od aktivity, ikony draft / review / CI / konflikt; large + tray navíc štítky, komentáře, +/- řádků, revieweři |
| Notifikace | v1; per pohled zapínatelné události z pevné sady, **výchozí všechny zapnuté**, nastavitelné v onboardingu |
| Struktura | XcodeGen `project.yml` jako zdroj pravdy, xcodeproj v `.gitignore`; logika v lokálních SPM balíčcích |
| Milestony | GitHub end-to-end → GitLab → notifikace + onboarding → OAuth → App Store; TestFlight průběžně |
| Distribuce | App Store primárně; notarizovaný Developer ID build v GitHub Releases bez auto-update |
| Lokalizace | jen EN (String Catalog od začátku, aby šla CS dodat levně) |
| Licence | MIT, veřejný repozitář |

## Architektura

```
┌──────────────── Gitwall.app (menu bar agent, sandbox) ────────────────┐
│ SyncEngine (actor) ── GitProvider[] ── GitHubProvider / GitLabProvider │
│      │ normalizuje → WorkItem[]  → SnapshotStore (JSON, App Group)     │
│      │ diff proti předchozímu → NotificationDispatcher                 │
│      └→ WidgetCenter.reloadAllTimelines()                              │
│ ConfigStore (JSON, App Group) · TokenStore (Keychain, jen app)         │
│ StatusItemController (NSStatusItem + NSPopover + NSMenu)               │
│ SettingsWindow (SwiftUI): Účty · Repozitáře · Pohledy · Notifikace     │
│ URL handler gitwall:// (item/…, view/…, refresh)                       │
└────────────────────────────────────────────────────────────────────────┘
                 ▲ čte config.json + snapshot.json + avatars/
┌──────── GitwallWidget.appex (WidgetKit) ───────┐
│ AppIntentConfiguration → ViewEntity (pohled)    │
│ TimelineProvider: načte snapshot, aplikuje      │
│ filtry pohledu, seřadí, ořízne na velikost      │
│ Řádek = Link(gitwall://item/<id>)               │
└─────────────────────────────────────────────────┘
```

Zásady:
- Providery znají jen `GitwallCore`. Nic providerově specifického neprosakuje do UI. Terminologie: model používá `pullRequest`; provider dodá `displayTerm` („PR“ / „MR“).
- Widget nikdy nesahá na síť ani na Keychain. Když je snapshot starší než 3× interval, ukáže stáří a odkaz „Otevřít Gitwall“.
- Filtry se vyhodnocují lokálně nad snapshotem (`FilterEngine`), takže tray i widget dávají shodný výsledek. Provider může filtr „předfiltrovat“ na serveru, ale nesmí na tom záviset správnost.
- Swift 6 language mode, strict concurrency; stavové objekty jako `actor`, UI přes `@Observable`.

## Balíčky a targety

```
osx-gitcontrol/
├── project.yml                      # XcodeGen; targety Gitwall, GitwallWidget, GitwallTests
├── Makefile                         # generate, build, test, archive, notarize
├── Gitwall/                         # app target (App, StatusItem, Settings, Onboarding, URL handling)
├── GitwallWidget/                   # widget extension (intent, provider, views)
├── Packages/
│   ├── GitwallCore/                 # modely, GitProvider protokol, FilterEngine, Snapshot, Diff, Config
│   ├── GitwallGitHub/               # GitHubProvider (GraphQL + REST + device flow)
│   ├── GitwallGitLab/               # GitLabProvider (GraphQL + REST + PKCE)
│   ├── GitwallAuth/                 # AuthFlow protokol, Keychain TokenStore, ASWebAuthenticationSession wrapper
│   └── GitwallUI/                   # sdílené řádky, ikony stavů, formátování času (tray i widget)
├── Config/                          # entitlements, Info.plist šablony, xcconfig (bundle ID, team)
├── docs/                            # privacy policy (GitHub Pages), screenshoty
├── .github/workflows/ci.yml
├── LICENSE (MIT), README.md, CLAUDE.md
```

Balíčky mají vlastní testy (`swift test`), CI je pouští bez Xcode UI.

## Doménový model (GitwallCore)

```swift
enum ProviderKind: String, Codable { case github, gitlab }

struct Account: Codable, Identifiable {
    let id: UUID; var kind: ProviderKind; var baseURL: URL           // https://api.github.com | https://gitlab.example.com
    var displayName: String; var me: UserRef                          // login + id pro filtr „já“
    var authMethod: AuthMethod                                        // .pat | .oauth(clientID)
    var nativeQuery: String?                                          // rozšíření per účet
    var sources: [RepoSource]                                         // explicitní repa i dynamické org/skupiny
}
enum RepoSource: Codable { case repository(fullName: String); case organization(String); case group(fullPath: String, includeSubgroups: Bool) }

enum ItemKind: String, Codable { case pullRequest, issue }
struct WorkItem: Codable, Identifiable, Hashable {
    let id: String                     // "\(accountID)/\(repoFullName)#\(number)/\(kind)"
    let accountID: UUID; let kind: ItemKind
    let repoFullName: String; let number: Int; let title: String; let url: URL
    let author: UserRef; let createdAt: Date; let updatedAt: Date     // updatedAt = poslední aktivita, klíč řazení
    let isDraft: Bool; let labels: [Label]; let assignees: [UserRef]; let milestone: String?
    let commentCount: Int
    // jen PR:
    let reviewState: ReviewState?      // .approved, .changesRequested, .pending, .none
    let ciState: CIState?              // .success, .failure, .running, .none
    let mergeState: MergeState?        // .clean, .conflict, .unknown
    let reviewers: [UserRef]; let requestedReviewers: [UserRef]; let additions: Int?; let deletions: Int?
}

struct View: Codable, Identifiable {  // „pohled“ / preset
    let id: UUID; var name: String; var icon: String
    var scope: [ViewScope]             // (accountID, RepoSource) – libovolná kombinace napříč účty
    var kinds: Set<ItemKind>           // PR, issue, obojí
    var filter: ItemFilter             // viz níže
    var sort: SortOrder                // .lastActivity (výchozí), .created, .oldestFirst
    var notifications: NotificationSettings  // Set<NotificationEvent>, výchozí všechny
    var showCountInMenuBar: Bool
}
struct ItemFilter: Codable {
    var relation: Set<Relation>        // .authoredByMe, .reviewRequestedFromMe, .assignedToMe, .mentionsMe; prázdné = vše
    var includeDrafts: Bool; var labelsAny: [String]; var labelsNone: [String]
    var reviewStates: Set<ReviewState>; var ciStates: Set<CIState>; var mergeStates: Set<MergeState>
    var updatedWithinDays: Int?; var milestone: String?; var text: String?
}
enum NotificationEvent: String, Codable, CaseIterable { case newItem, reviewRequested, approved, changesRequested, ciFailed, merged, closed }

struct Snapshot: Codable { var schemaVersion: Int; var fetchedAt: Date; var items: [WorkItem]; var accountStatus: [UUID: FetchStatus] }
```

Soubory v App Group: `config.json` (účty bez tokenů, pohledy, nastavení), `snapshot.json`, `snapshot.previous.json` (pro diff a zvýraznění nových), `avatars/<hash>.png`. `schemaVersion` + migrace v `ConfigStore`.

## Protokol providera

```swift
protocol GitProvider: Sendable {
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }     // podporované server-side filtry, teamReviewRequests…
    func verify(token: Token, baseURL: URL) async throws -> UserRef
    func discoverRepositories(query: String?) async throws -> [RepoRef]
    func discoverContainers() async throws -> [ContainerRef]          // org / group
    func fetchItems(sources: [RepoSource], kinds: Set<ItemKind>, hint: FilterHint) async throws -> [WorkItem]
}
protocol AuthFlow { func signIn() async throws -> Token; func refreshIfNeeded(_ token: Token) async throws -> Token }
```

Strategie dotazů:
- **GitHub**: explicitní repa → jeden GraphQL request s aliasy `r0: repository(owner:,name:){ pullRequests(states: OPEN, first: 50, orderBy: UPDATED_AT DESC) … issues(...) }`, dávky po ~15 repech. Org jako dynamický zdroj → `search(query: "org:X is:pr is:open", type: ISSUE)` stránkovaně (limit 256 znaků dotazu a 1000 výsledků). Pole: `reviewDecision`, `isDraft`, `mergeable`, `commits(last:1){…statusCheckRollup{state}}`, `reviewRequests`, `latestReviews`, `labels`, `comments{totalCount}`, `additions`, `deletions`. Team review requests jen s `read:org` (capability flag).
- **GitLab**: complexity limit je 250 bodů na dotaz pro přihlášeného uživatele a jeden alias `project(fullPath:){ mergeRequests(first: 50) … }` stojí ~43 bodů, takže **max. 4 aliasy projektů na request**, běh s omezenou paralelitou (≤ 3 souběžné). Skupina → `group(fullPath:){ mergeRequests(includeSubgroups: true, state: opened, sort: UPDATED_DESC) }` (jeden dotaz na celou skupinu, preferovaná cesta). Každý dotaz přidává `queryComplexity { score limit }`, test hlídá, že score < 200. Nepoužívat experimentální root `Query.mergeRequests`. Pole: `draft`, `conflicts`, `approved`, `approvedBy`, `reviewers`, `assignees`, `headPipeline{status}`, `detailedMergeStatus`, `labels`, `userNotesCount`, `diffStatsSummary{additions deletions}`, `webUrl`, `updatedAt`, `author{username avatarUrl}` (všechna ověřena v `merge_request_type.rb`).
- **GitHub** poznámky: `mergeable` vrací `UNKNOWN`, dokud GitHub mergeabilitu nepočítá → `mergeState = .unknown`; `statusCheckRollup` je null bez checků → `ciState = .none`; `reviewDecision` je null, když review není vyžadováno. Vnořené connections s `first: 10`, odhad ~50 bodů na dotaz s 20 aliasy → při 5min intervalu ~600 bodů/h z 5000.
- Rate limit: čtení hlaviček, při 403/429 exponenciální zpomalení, stav se ukáže v tray a ve snapshotu (`FetchStatus`).
- TLS: systémový trust store (firemní CA přes macOS Keychain), žádné vypínání ověření. Proxy: systémové přes URLSession.

## Auth

- `TokenStore` nad Security frameworkem, položky per `Account.id`, `kSecAttrAccessibleAfterFirstUnlock`, jen v app targetu (widget tokeny nepotřebuje).
- PAT: vložení + `verify()` → uloží `me`. Nápověda scope: GitHub classic `repo` + `read:org`, fine-grained Pull requests/Issues/Commit statuses/Contents read (Contents kvůli stavu CI, jeden vlastník na token); GitLab legacy `read_api`, fine-grained (19.2+) podle tabulky v README „Personal access tokens“.
- GitHub.com device flow: veřejný client ID naší OAuth App, polling s respektem k `interval` / `slow_down`. GHES: uživatel zadá vlastní client ID.
- GitLab.com Authorization Code + PKCE přes `ASWebAuthenticationSession`, callback `gitwall://oauth/gitlab`, scopes `read_api read_user`. Self-host: PAT výchozí, volitelné vlastní client ID.

**Požadavek: uživatel se přihlašuje jednou.** Expirace tokenů je čistě interní záležitost aplikace, uživatel ji nikdy nesmí vidět jako opakované přihlášení.
- `Token` nese `accessToken`, `refreshToken?`, `expiresAt?`; oba tokeny v Keychainu, zápis nového páru atomicky (rotace refresh tokenu u GitLabu: starý refresh token po použití neplatí, takže ztráta nového páru = ztráta přihlášení).
- `TokenRefresher` (actor per účet) obnoví access token proaktivně, když zbývá < 10 min do expirace, a reaktivně při 401; souběžné požadavky čekají na jednu probíhající obnovu (žádné dvojí použití refresh tokenu).
- GitHub OAuth App tokeny z device flow neexpirují (bez zapnuté expirace), obnova se netýká. GitLab refresh tokeny neexpirují časem, jen použitím nebo revokací.
- Retry: při síťové chybě obnovy se ponechá stávající token a zkusí se znovu při dalším syncu; při `invalid_grant` (revokace, změna hesla, admin zásah) se účet označí `needsReauth`, v tray se zobrazí jedna nenápadná výzva „Přihlaste se znovu k účtu X“ s tlačítkem, žádné modální okno a žádné opakované vyskakování. Data z posledního snapshotu zůstávají viditelná.
- PAT bez expirace se chová stejně; PAT s nastavenou expirací (GitHub fine-grained, GitLab) → aplikace čte datum expirace z API, kde je dostupné, a týden předem upozorní v nastavení.
- Testy: simulace expirace, rotace, souběhu dvou synců a `invalid_grant` nad falešným OAuth serverem (URLProtocol mock).

## UI

- **StatusItemController** (AppKit): `NSStatusItem` s ikonou + volitelným počtem z pohledu se `showCountInMenuBar`; levý klik `NSPopover` s `NSHostingController(PopoverView)`, pravý klik `NSMenu` (SwiftUI `MenuBarExtra` pravý klik neumí). Dock toggle přes `NSApp.setActivationPolicy`; známá chyba po přepnutí `.accessory → .regular` (hlavní menu neaktivní) se obchází `NSApp.activate` se zpožděním ~200 ms. Testovat pravý klik i na horním pixelu lišty (známý problém na macOS 26).
- **PopoverView**: segment/picker pohledů, seznam `WorkItemRow` (z `GitwallUI`), stav synchronizace a stáří, tlačítka Obnovit / Nastavení. Klik otevře URL přes `NSWorkspace`, pravý klik kopíruje URL, nové položky (diff) mají tečku.
- **SettingsWindow** (SwiftUI `Settings` scene): záložky Účty (přidat/ověřit/odebrat, nativní dotaz), Repozitáře (discovery s hledáním, org/skupina, ruční zápis), Pohledy (editor filtrů + notifikace), Obecné (interval, Dock ikona, spouštění při přihlášení).
- **Onboarding** při prvním spuštění: vítejte → přidat účet → vybrat repa → vytvořit výchozí pohledy („Moje PR“, „Čeká na můj review“, „Vše otevřené“) → notifikace (vše zapnuté, lze upravit, žádost o oprávnění) → spouštění při přihlášení → „přidejte widget na plochu“ s návodem.
- **Widget**: `AppIntentConfiguration` s `ViewEntity` (EntityQuery čte `config.json`). Small: název pohledu, počet, nejnovější položka. Medium: 3–4 řádky. Large: 8–10 řádků. ExtraLarge: dva sloupce. Řádek = `Link(gitwall://item/<id>)`, hlavička = `Link(gitwall://view/<id>)`, obnova = `Link(gitwall://refresh)` (WidgetKit spustí app, když neběží). Žádné `Button(intent:)` pro otevření app: Apple to výslovně nedoporučuje a `openAppWhenRun` je v macOS 26 SDK deprecated. `widgetURL(gitwall://view/<id>)` jako fallback pro klik mimo řádky. Avatary z `avatars/` v App Group, zmenšené na ≤ 96 px, max. ~12 na entry (paměťový limit widgetu ~30 MB). Prázdný stav: „Žádné položky“ nebo „Nastavte účet v Gitwall“.
- **URL handler** v app: povinně v `NSApplicationDelegate.application(_:open:)` (ne `onOpenURL` na SwiftUI view, které u menu bar app nemusí existovat); schéma `gitwall` v `CFBundleURLTypes`. `item/<id>` → najde položku ve snapshotu, otevře `url` v prohlížeči; `view/<id>` → otevře popover na pohledu; `refresh` → spustí sync. Pozor na duplicitní debug bundly, které Launch Services registruje na stejné schéma.

## Notifikace

`NotificationDispatcher` porovná `snapshot.previous.json` a nový snapshot per pohled a podle `View.notifications` vytvoří `UNNotificationRequest` (titulek = událost, tělo = název + repo, `userInfo.itemID`). Klik otevře PR. Sloučení při první synchronizaci po startu (žádná salva). Oprávnění se žádá v onboardingu.

## Milestony

### M0 – Kostra projektu
- Přejmenovat GitHub repo `prokopsimek/osx-gitcontrol` → `prokopsimek/gitwall` (`gh repo rename`), aktualizovat `origin`; lokální složka zůstává.
- `project.yml` (targety Gitwall, GitwallWidget, GitwallTests; entitlements: sandbox, network client, app groups, keychain), `Makefile` (`generate`, `test`, `archive`), `.gitignore` (xcodeproj), `LICENSE`, `README.md`, `CLAUDE.md` (konvence: Swift 6, TDD v balíčcích, generování projektu), CI (`macos` runner: xcodegen + swift test + xcodebuild build).
- App Group `ZHU9NYW7PP.cz.prokopsimek.gitwall` (Team-ID style; see AppGroup.swift for why) zaregistrovat v developer portálu (iOS-style ID je od února 2025 podporované na macOS a Apple ho pro nový kód doporučuje), zapnout automatické podepisování, aby se dostalo do Mac provisioning profilu; nemíchat s `<TEAMID>.`-stylem (ITMS-90286). Bez správného profilu systém extension tiše odepře přístup a widget neuvidí snapshot.
- Prázdná app se status itemem a prázdným widgetem; **ověřit na zařízení**, že widget přečte soubor zapsaný appkou do App Group (bez dialogu o přístupu k datům jiných aplikací).

### M1 – GitHub end-to-end (PAT)
- `GitwallCore`: modely, `ConfigStore`, `SnapshotStore`, `FilterEngine`, `SnapshotDiff`, `SyncEngine` – vše s testy.
- `GitwallGitHub`: GraphQL klient, dotazy pro repa/org, mapování na `WorkItem`, discovery rep a org, verify; testy nad fixture JSON.
- `GitwallAuth`: `TokenStore` (Keychain) s testy přes in-memory implementaci.
- App: Účty (PAT), Repozitáře, Pohledy (základní filtry: typ, vztah ke mně, draft), Obecné; popover; URL handler; launch at login; Dock toggle.
- Widget: konfigurace pohledem, 4 velikosti, odkazy, avatar cache.
- TestFlight build 0.1.

### M2 – GitLab
- `GitwallGitLab`: GraphQL dotazy project/group, REST discovery, verify; testy nad fixture JSON. Ověření na GitLab.com i self-host (minimální podporovaná verze zdokumentovat, cíl GitLab ≥ 16).
- Pohled napříč účty (GitHub + GitLab) v jednom widgetu.

### M3 – Filtry, notifikace, onboarding
- Plné filtry (štítky, review/CI/merge stav, stáří, milestone, text) + nativní dotaz per účet.
- `NotificationDispatcher`, nastavení per pohled, výchozí vše zapnuté.
- Onboarding flow, prázdné stavy, stav rate limitu v tray.

### M4 – OAuth
- GitHub device flow (registrace OAuth App, client ID v `Config/`), GitLab PKCE; vlastní client ID pro self-host.
- `TokenRefresher` s tichou obnovou, rotací a stavem `needsReauth` (viz sekce Auth); testy nad mock OAuth serverem. Akceptační kritérium: účet přihlášený přes OAuth funguje týdny bez jediného dalšího přihlašovacího dialogu.

### M5 – App Store a Releases
- Ikona, screenshoty, privacy policy na GitHub Pages (`docs/`) a odkaz na ni i uvnitř app (O aplikaci), App Store Connect záznam „Gitwall“ (ověřit dostupnost názvu; podtitul „Pull requests and issues on your desktop“, „for Mac“ jen v marketingu), review poznámky s testovacím účtem.
- Developer ID build + notarizace (`make notarize`), GitHub Release workflow.

## Ověření (po každém milestonu)

1. `make generate && swift test --package-path Packages/GitwallCore` (a ostatní balíčky) – jednotkové testy modelů, filtrů, diffu, mapování providerů nad fixture JSON.
2. `xcodebuild -scheme Gitwall -destination 'platform=macOS' build test` – sestavení app i widgetu.
3. Ruční E2E: spustit app, přidat účet s PAT proti reálnému repu, ověřit seznam v popoveru; přidat widget všech 4 velikostí na plochu, vybrat pohled, kliknout na řádek → otevře se PR v prohlížeči; odpojit síť → widget ukáže stáří dat; zapnout notifikaci a vyvolat změnu (nový PR) → přijde notifikace, klik otevře PR.
4. Kontrola sandboxu: `codesign -d --entitlements - Gitwall.app`, ověřit App Group a absenci zbytečných entitlements.
5. Před M5: archiv přes `xcodebuild archive` + upload do TestFlight, průchod App Store review checklistem (privacy policy, název bez ochranných známek, popis oprávnění pro notifikace).

## Ověřené předpoklady (agent, 2026-09-10, zdroje Apple / GitHub / GitLab dokumentace)

- `Link` s vlastním schématem ve widgetu spustí a aktivuje obsahující app; obsluha musí být v `application(_:open:)`.
- Interaktivní tlačítko ve widgetu se nemá používat k otevření app; `openAppWhenRun` je v macOS 26 deprecated.
- App Group: iOS-style `group.` ID, registrace v portálu, v provisioning profilu; extension bez oprávnění je tiše odmítnuta.
- GitHub search: max. 256 znaků dotazu, 1000 výsledků; alias batching 20 rep je v pořádku (~50 bodů/dotaz).
- GitHub device flow: jen client ID, tokeny OAuth App neexpirují, GHES podporuje s vlastní OAuth App.
- GitLab PKCE bez secretu s custom schématem funguje (používá i oficiální VS Code extension); access token 2 h, refresh s rotací; device grant až od GitLab 17.9 GA, proto PKCE jako primární.
- GitLab GraphQL complexity 250 → max. 4 aliasy projektů na dotaz, preferovat skupinové dotazy.
- Privacy policy povinná i pro bezplatnou app, odkaz v metadatech i v app. Název „Gitwall“ bez ochranných známek Apple.

## Zbývající otevřené body

- Zda `containerURL(forSecurityApplicationGroupIdentifier:)` na macOS vrací nil při špatné konfiguraci, nebo jen odepře přístup k souborům (ověřit v M0 na zařízení).
- Dostupnost názvu „Gitwall“ v App Store Connect (ověřit před M5, ideálně rezervovat záznam už v M1).
- Minimální podporovaná verze self-managed GitLabu (pole `detailedMergeStatus` a `approved` existují od 15.x; cíl ≥ 16, ověřit na reálné instanci v M2).
