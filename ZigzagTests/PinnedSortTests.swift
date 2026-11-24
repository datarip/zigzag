import AppKit
import Testing
@testable import Zigzag

/// The pinned tree the sorter is tested against. Folder names and page titles are out of order, and it has R2 and R10,
/// a pinned split whose right page comes first, a shut folder, an empty folder, two folders named alike and a chain
/// three folders deep. The sorter takes the values themselves, so no window is needed.
@MainActor
struct PinnedSortFixture {
    typealias Sorted = (bookmarks: [Bookmark], folders: [BookmarkFolder], splits: [PinnedSplit])

    private(set) var bookmarks: [Bookmark] = []
    private(set) var folders: [BookmarkFolder] = []
    private(set) var splits: [PinnedSplit] = []

    // MARK: Building

    @discardableResult
    mutating func page(_ title: String) -> UUID {
        let bookmark = Bookmark(url: URL(string: "https://example.com/\(UUID().uuidString)")!, title: title)
        bookmarks.append(bookmark)
        return bookmark.id
    }

    @discardableResult
    mutating func folder(_ name: String, parent: UUID? = nil, open: Bool = true, holding pages: [UUID] = []) -> UUID {
        var folder = BookmarkFolder(name: name, bookmarkIDs: pages)
        folder.parentID = parent
        folder.isOpen = open
        folders.append(folder)
        return folder.id
    }

    mutating func split(_ left: UUID, _ right: UUID) {
        splits.append(PinnedSplit(left: left, right: right))
    }

    /// Work holds E and A, and the subfolders Old (D) and Docs (C, B), added Old first. Reading holds R10, R2, R1, R12
    /// and R11 in that order. Zeta, Alpha and the two Twins are top level, Shut is shut and Empty has no pages. Deep1
    /// holds Deep2b, then Deep2a (D2, whose own Deep3 holds P) and D1. F, S0, S1a and the split S1|S2 are top level.
    static func standard() -> PinnedSortFixture {
        var tree = PinnedSortFixture()
        let r10 = tree.page("R10"), r2 = tree.page("R2"), r1 = tree.page("R1")
        let r12 = tree.page("R12"), r11 = tree.page("R11")
        let e = tree.page("E"), a = tree.page("A")
        let c = tree.page("C"), b = tree.page("B"), d = tree.page("D")
        let x2 = tree.page("X2"), x1 = tree.page("X1")
        let z1 = tree.page("Z1"), al1 = tree.page("Al1")
        let d1 = tree.page("D1"), d2 = tree.page("D2"), p = tree.page("P")
        let ta = tree.page("TA"), tb = tree.page("TB")
        let s2 = tree.page("S2"), s1 = tree.page("S1")
        tree.page("F")
        tree.page("S1a")
        tree.page("S0")

        tree.folder("Reading", holding: [r10, r2, r1, r12, r11])
        let work = tree.folder("Work", holding: [e, a])
        tree.folder("Old", parent: work, holding: [d])
        tree.folder("Docs", parent: work, holding: [c, b])
        tree.folder("Zeta", holding: [z1])
        tree.folder("Alpha", holding: [al1])
        tree.folder("Shut", open: false, holding: [x2, x1])
        tree.folder("Empty")
        let deep1 = tree.folder("Deep1", holding: [d1])
        tree.folder("Deep2b", parent: deep1)
        let deep2a = tree.folder("Deep2a", parent: deep1, holding: [d2])
        tree.folder("Deep3", parent: deep2a, holding: [p])
        tree.folder("Twin", holding: [tb])
        tree.folder("Twin", holding: [ta])
        tree.split(s1, s2)
        return tree
    }

    // MARK: Lookups

    func pageID(_ title: String) throws -> UUID {
        try #require(bookmarks.first { $0.title == title }?.id)
    }

    func folderID(_ name: String, _ occurrence: Int = 0) throws -> UUID {
        try #require(folders.filter { $0.name == name }.dropFirst(occurrence).first?.id)
    }

    // MARK: What the sorter and the list make of it

    func sorted() -> Sorted {
        Library.sortedPinned(bookmarks: bookmarks, folders: folders, splits: splits)
    }

    /// The rows the list draws from a sorted tree, with how far in each sits. Every page is taken as open, so a shut
    /// folder shows the pages opened since it was shut.
    func layout(_ sorted: Sorted) -> (rows: [SidebarItem], depth: [SidebarItem: Int]) {
        let riding = Set(sorted.splits.flatMap(\.riders))
        let shown = SidebarListView.pinnedRows(bookmarks: sorted.bookmarks.map(\.id), folders: sorted.folders,
                                               riders: riding, current: nil, isOpen: { _ in true })
        return (shown.rows, shown.depth)
    }

    /// Where an item's row sits, top to bottom.
    func at(_ item: SidebarItem, in rows: [SidebarItem]) throws -> Int {
        try #require(rows.firstIndex(of: item))
    }
}

/// Sorting a workspace's pinned folders and pages: folders before pages at every level, each by name or title, with a
/// pinned split kept as one unit.
@MainActor
struct PinnedSortTests {
    let tree = PinnedSortFixture.standard()

    /// Top-level folders come out in name order, wherever they were in the list.
    @Test func topLevelFoldersSortByName() throws {
        let sorted = tree.sorted()
        let layout = tree.layout(sorted)
        var top: [SidebarItem] = []
        for row in layout.rows where layout.depth[row] == 0 {
            if case .folder = row { top.append(row) }
        }
        let expected = [try tree.folderID("Alpha"), try tree.folderID("Deep1"), try tree.folderID("Empty"),
                        try tree.folderID("Reading"), try tree.folderID("Shut"), try tree.folderID("Twin", 0),
                        try tree.folderID("Twin", 1), try tree.folderID("Work"), try tree.folderID("Zeta")]
        #expect(top == expected.map(SidebarItem.folder))
    }

    /// Child folders sort inside each parent, in every folder that has them.
    @Test func childFoldersSortInsideEachParent() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let docsAt = try tree.at(.folder(try tree.folderID("Docs")), in: rows)
        let oldAt = try tree.at(.folder(try tree.folderID("Old")), in: rows)
        let deep2aAt = try tree.at(.folder(try tree.folderID("Deep2a")), in: rows)
        let deep2bAt = try tree.at(.folder(try tree.folderID("Deep2b")), in: rows)
        #expect(docsAt < oldAt)
        #expect(deep2aAt < deep2bAt)
    }

    /// Every top-level folder, with its whole subtree, comes before the lone top-level pages.
    @Test func topLevelPagesSortAfterEveryFolderAndItsSubtree() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let fAt = try tree.at(.bookmark(try tree.pageID("F")), in: rows)
        let zetaAt = try tree.at(.folder(try tree.folderID("Zeta")), in: rows)
        let z1At = try tree.at(.bookmark(try tree.pageID("Z1")), in: rows)
        let lastTopPage = try tree.at(.bookmark(try tree.pageID("S1a")), in: rows)
        #expect(fAt > zetaAt)
        #expect(fAt > z1At)
        #expect(lastTopPage == rows.count - 1)
    }

    /// Inside a folder, its child folders come first and its own pages after them.
    @Test func pagesInsideAFolderSortAfterItsChildFolders() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let docsAt = try tree.at(.folder(try tree.folderID("Docs")), in: rows)
        let oldAt = try tree.at(.folder(try tree.folderID("Old")), in: rows)
        let aAt = try tree.at(.bookmark(try tree.pageID("A")), in: rows)
        let eAt = try tree.at(.bookmark(try tree.pageID("E")), in: rows)
        let bAt = try tree.at(.bookmark(try tree.pageID("B")), in: rows)
        let cAt = try tree.at(.bookmark(try tree.pageID("C")), in: rows)
        #expect(docsAt < oldAt)
        #expect(oldAt < aAt)
        #expect(aAt < eAt)
        #expect(bAt < cAt)
    }

    /// Three levels of folders sort at every one of them.
    @Test func threeOrMoreLevelsSortAtEveryLevel() throws {
        let sorted = tree.sorted()
        let layout = tree.layout(sorted)
        let rows = layout.rows
        let deep2aAt = try tree.at(.folder(try tree.folderID("Deep2a")), in: rows)
        let deep2bAt = try tree.at(.folder(try tree.folderID("Deep2b")), in: rows)
        let deep3At = try tree.at(.folder(try tree.folderID("Deep3")), in: rows)
        let d1At = try tree.at(.bookmark(try tree.pageID("D1")), in: rows)
        let d2At = try tree.at(.bookmark(try tree.pageID("D2")), in: rows)
        let p = try tree.pageID("P")
        let pAt = try tree.at(.bookmark(p), in: rows)
        #expect(deep2aAt < deep2bAt)
        #expect(deep2bAt < d1At)
        #expect(deep3At < d2At)
        #expect(pAt < d2At)
        #expect(layout.depth[.bookmark(p)] == 3)
    }

    /// A shut folder's pages sort too, and it stays shut with the pages opened since showing under it.
    @Test func aShutFoldersPagesSortAndItStaysShut() throws {
        let sorted = tree.sorted()
        let shut = try #require(sorted.folders.first { $0.name == "Shut" })
        let x1 = try tree.pageID("X1"), x2 = try tree.pageID("X2")
        #expect(!shut.isOpen)
        #expect(shut.bookmarkIDs == [x1, x2])
        let rows = tree.layout(sorted).rows
        let x1At = try tree.at(.bookmark(x1), in: rows)
        let x2At = try tree.at(.bookmark(x2), in: rows)
        #expect(x1At < x2At)
        #expect(rows.contains(.bookmark(x1)) && rows.contains(.bookmark(x2)))
    }

    /// An empty folder is a folder: it sorts with the folders, not with the pages.
    @Test func anEmptyFolderSortsWithTheFolders() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let empty = try tree.folderID("Empty")
        let deep1At = try tree.at(.folder(try tree.folderID("Deep1")), in: rows)
        let emptyAt = try tree.at(.folder(empty), in: rows)
        let readingAt = try tree.at(.folder(try tree.folderID("Reading")), in: rows)
        let fAt = try tree.at(.bookmark(try tree.pageID("F")), in: rows)
        #expect(deep1At < emptyAt)
        #expect(emptyAt < readingAt)
        #expect(emptyAt < fAt)
        #expect((sorted.folders.first { $0.id == empty }?.rank ?? 0) < 0)
    }

    /// A pinned split is one page unit, led by its first page. The unit sorts by S1's title, not S2's. The two stay
    /// side by side with S2 riding in S1's row.
    @Test func aPinnedSplitStaysOneUnitAndSortsByItsFirstPage() throws {
        let sorted = tree.sorted()
        let ids = sorted.bookmarks.map(\.id)
        let s0 = try tree.pageID("S0"), s1 = try tree.pageID("S1"), s2 = try tree.pageID("S2"), s1a = try tree.pageID("S1a")
        let atS1 = try #require(ids.firstIndex(of: s1))
        #expect(ids[atS1 + 1] == s2)
        let rows = tree.layout(sorted).rows
        let s0At = try tree.at(.bookmark(s0), in: rows)
        let s1At = try tree.at(.bookmark(s1), in: rows)
        let s1aAt = try tree.at(.bookmark(s1a), in: rows)
        #expect(s0At < s1At)
        #expect(s1At < s1aAt)
        #expect(sorted.splits == [PinnedSplit(left: s1, right: s2)])
        #expect(rows.contains(.bookmark(s1)) && !rows.contains(.bookmark(s2)))
    }

    /// A page no folder lists stays pinned at the top level, and no page is lost.
    @Test func aPageInNoFolderIsKeptAtTheTopLevel() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let f = try tree.pageID("F")
        #expect(sorted.bookmarks.map(\.id).contains(f))
        #expect(sorted.folders.allSatisfy { !$0.bookmarkIDs.contains(f) })
        #expect(rows.contains(.bookmark(f)))
        #expect(Set(sorted.bookmarks.map(\.id)) == Set(tree.bookmarks.map(\.id)))
        #expect(sorted.bookmarks.count == tree.bookmarks.count)
    }

    /// Two folders with the same name keep the order they had. A new order on every sort would move them.
    @Test func twoEqualNamesKeepTheirPreviousOrder() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let firstAt = try tree.at(.folder(try tree.folderID("Twin", 0)), in: rows)
        let secondAt = try tree.at(.folder(try tree.folderID("Twin", 1)), in: rows)
        #expect(firstAt < secondAt)
    }

    /// R2 comes before R10, as Finder sorts names with numbers in them.
    @Test func r2ComesBeforeR10() throws {
        let sorted = tree.sorted()
        let rows = tree.layout(sorted).rows
        let r1At = try tree.at(.bookmark(try tree.pageID("R1")), in: rows)
        let r2At = try tree.at(.bookmark(try tree.pageID("R2")), in: rows)
        let r10At = try tree.at(.bookmark(try tree.pageID("R10")), in: rows)
        let r11At = try tree.at(.bookmark(try tree.pageID("R11")), in: rows)
        let r12At = try tree.at(.bookmark(try tree.pageID("R12")), in: rows)
        #expect(r1At < r2At)
        #expect(r2At < r10At)
        #expect(r10At < r11At)
        #expect(r11At < r12At)
    }

    /// The result is already tidy: running the folder and split rule again changes nothing and breaks no split.
    @Test func theResultPassesTidiedUnchanged() throws {
        let sorted = tree.sorted()
        let again = Library.tidied(sorted.bookmarks, sorted.folders, sorted.splits)
        #expect(again.bookmarks == sorted.bookmarks)
        #expect(again.folders == sorted.folders)
        #expect(again.splits == sorted.splits)
    }
}

/// The library's own sort: one space's pins change, and another space's pins, the favorites and the tabs are left be.
@MainActor
struct PinnedSortLibraryTests {
    @Test func sortingOneSpaceLeavesTheOthersAndTheFavoritesAlone() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Sort Space").id
        let other = Library.shared.addSpace(name: "Sort Space Other").id
        let pages = Library.shared.appendBookmarks(
            (0..<5).map { (URL(string: "http://127.0.0.1:9/sort/\($0)")!, "P\($0)") },
            to: space,
            folders: [["Work"], ["Work", "Docs"], ["Reading"], ["Reading"], []])
        _ = Library.shared.appendBookmarks([(URL(string: "http://127.0.0.1:9/sort/other")!, "O")], to: other)
        let otherBefore = try #require(Library.shared.space(other))
        let favoritesBefore = Library.shared.favorites
        let splitsBefore = Library.shared.favoriteSplits

        Library.shared.sortPinnedTabs(in: space)

        // Reading comes before Work. Inside Work the child folder Docs comes before Work's own page.
        let order = Library.shared.bookmarks(in: space).map(\.title)
        #expect(order == ["P2", "P3", "P1", "P0", "P4"])
        let folders = Library.shared.folders(in: space)
        let reading = try #require(folders.first { $0.name == "Reading" })
        let work = try #require(folders.first { $0.name == "Work" })
        #expect((reading.rank ?? 0) < (work.rank ?? 0))
        #expect((work.rank ?? 0) < 0)
        #expect(folders.first { $0.name == "Docs" }?.bookmarkIDs == [pages[1].id])
        #expect(Library.shared.space(other) == otherBefore)
        #expect(Library.shared.favorites == favoritesBefore)
        #expect(Library.shared.favoriteSplits == splitsBefore)
    }

    /// A second sort of an already sorted space changes nothing, so there is no undo step for it either.
    @Test func sortingAnAlreadySortedSpaceChangesNothing() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Sort Again").id
        _ = Library.shared.appendBookmarks(
            (0..<4).map { (URL(string: "http://127.0.0.1:9/sort/again/\($0)")!, "P\($0)") },
            to: space,
            folders: [["Zeta"], ["Alpha"], []])
        Library.shared.sortPinnedTabs(in: space)
        let sorted = Library.shared.space(space)
        Library.shared.sortPinnedTabs(in: space)
        #expect(Library.shared.space(space) == sorted)
    }
}

/// A recorded measurement of the sorter, for the shipping notes. It builds the three trees the sort plan names and
/// times `Library.sortedPinned` alone, three runs each and the best of them. The sidebar reload is a window, so it is
/// not measured here. It only runs when asked:
///
///     TEST_RUNNER_ZIGZAG_TEST_VAULT=memory TEST_RUNNER_ZIGZAG_SORT_BENCH=1 xcodebuild test \
///       -project Zigzag.xcodeproj -scheme Zigzag -derivedDataPath build/dd \
///       -only-testing:ZigzagTests/PinnedSortBench
@MainActor
struct PinnedSortBench {
    @Test func theThreeSizes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TEST_RUNNER_ZIGZAG_SORT_BENCH"] == "1" || environment["ZIGZAG_SORT_BENCH"] == "1" else { return }
        for (pages, folders) in [(20_000, 200), (20_000, 20_000), (20_000, 314)] {
            let tree = Self.tree(pages: pages, folders: folders)
            var seconds: [Double] = []
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let sorted = Library.sortedPinned(bookmarks: tree.bookmarks, folders: tree.folders, splits: [])
                let end = DispatchTime.now().uptimeNanoseconds
                seconds.append(Double(end - start) / 1_000_000_000)
                #expect(sorted.bookmarks.count == pages)
            }
            let runs = seconds.map { String(format: "%.3f", $0) }.joined(separator: ",")
            print(String(format: "sortbench pages=%d folders=%d best=%.3f s runs=%@", pages, folders, seconds.min() ?? 0, runs))
        }
    }

    private static func tree(pages: Int, folders: Int) -> (bookmarks: [Bookmark], folders: [BookmarkFolder]) {
        var bookmarks: [Bookmark] = []
        bookmarks.reserveCapacity(pages)
        for index in 0..<pages {
            bookmarks.append(Bookmark(url: URL(string: "https://example.com/\(index)")!, title: "Page \(index)"))
        }
        var made: [BookmarkFolder] = []
        made.reserveCapacity(folders)
        for index in 0..<folders {
            let start = index * pages / folders, end = (index + 1) * pages / folders
            made.append(BookmarkFolder(name: "Folder \(index)", bookmarkIDs: bookmarks[start..<end].map(\.id)))
        }
        return (bookmarks, made)
    }
}
