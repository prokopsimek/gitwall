import Foundation
import GitwallCore
import Testing
@testable import GitwallUI

@Suite("Tile rows")
struct TileRowsTests {
    private func items(_ count: Int) -> [WorkItem] {
        (1...max(count, 1)).prefix(count).map { number in
            WorkItem(accountID: UUID(), kind: .pullRequest, repoFullName: "acme/app", number: number, title: "#\(number)",
                     url: URL(string: "https://example.com/\(number)")!, author: UserRef(login: "a"),
                     createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test("a tile lists as many items as its size allows and counts the rest")
    func limits() {
        for size in TileSize.allCases {
            let rows = TileRows(items: items(20), size: size)
            #expect(rows.visible.count == size.rowLimit)
            #expect(rows.hidden == 20 - size.rowLimit)
        }
        let few = TileRows(items: items(2), size: .large)
        #expect(few.visible.count == 2)
        #expect(few.hidden == 0)
    }

    @Test("extra large splits its items into two columns, the first one fuller; the others use one")
    func columns() {
        let wide = TileRows(items: items(9), size: .extraLarge)
        #expect(wide.columns.map { $0.map(\.number) } == [[1, 2, 3, 4, 5], [6, 7, 8, 9]])
        #expect(wide.visible.map(\.number) == Array(1...9))
        let medium = TileRows(items: items(5), size: .medium)
        #expect(medium.columns.map { $0.map(\.number) } == [[1, 2, 3]])
    }

    @Test("no items, no rows")
    func empty() {
        let rows = TileRows(items: [], size: .extraLarge)
        #expect(rows.visible.isEmpty)
        #expect(rows.hidden == 0)
        #expect(rows.columns.allSatisfy { $0.isEmpty })
    }
}
