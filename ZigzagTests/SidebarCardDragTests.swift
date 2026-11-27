import AppKit
import Testing
@testable import Zigzag

/// The card and favorite drag fixes from the third hand test: one drop for the line and the landing, a card kept
/// at the top level or demoted inside a folder, cross-window grids, the shut folder's wait and flash, and the
/// favorites-only numbers.
@MainActor
struct SidebarCardDragTests {
    /// Runs `body` against a fresh library, putting the saved one back afterwards.
    private func withLibrary(_ body: () throws -> Void) rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        try body()
    }

    private struct Tree {
        let space: UUID
        let a: Bookmark, b: Bookmark, c: Bookmark, d: Bookmark, e: Bookmark
        let work: BookmarkFolder, docs: BookmarkFolder, old: BookmarkFolder
    }

    private func makeTree() throws -> Tree {
        let space = Library.shared.spaces[0].id
        func page(_ title: String, _ path: String) throws -> Bookmark {
            try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/\(path)")!, title: title, to: space))
        }
        let a = try page("A", "a"), b = try page("B", "b"), c = try page("C", "c"), d = try page("D", "d"), e = try page("E", "e")
        let work = try #require(Library.shared.addFolder(named: "Work", with: [a.id, e.id], in: space))
        let docs = try #require(Library.shared.addFolder(named: "Docs", with: [b.id, c.id], in: space, parent: .some(work.id)))
        let old = try #require(Library.shared.addFolder(named: "Old", with: [d.id], in: space, parent: .some(work.id)))
        return Tree(space: space, a: a, b: b, c: c, d: d, e: e, work: work, docs: docs, old: old)
    }

    private func window(_ manager: TabManager) -> BrowserWindowController {
        BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    private func screenPoint(_ topLeft: NSPoint, in window: NSWindow) -> NSPoint {
        window.convertPoint(toScreen: NSPoint(x: topLeft.x, y: window.frame.height - topLeft.y))
    }

    /// The middle of a row as it is on screen now, after any layout that followed the first read.
    private func point(of row: NSView, in window: NSWindow) -> NSPoint {
        window.convertPoint(toScreen: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
    }

    private func rows(_ list: SidebarListView) -> [String: NSRect] {
        Dictionary(uniqueKeysWithValues: list.debugRows().map { ($0.0, $0.1) })
    }

    /// X1 above Old: the line draws above Old and the drop lands above Old, inside Work.
    @Test func aFavoriteOverOldDrawsAndLandsAtTheSameGap() throws {
        try withLibrary {
            let tree = try makeTree()
            let profile = Library.shared.profileID(ofSpace: tree.space)
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
            let manager = TabManager(spaceID: tree.space)
            defer { manager.invalidate() }
            let controller = window(manager)
            defer { controller.window?.close() }
            controller.window?.orderFront(nil)
            let list = controller.sidebar.list
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let frames = rows(list)
            let old = try #require(frames["folder:Old"])
            let d = try #require(frames["pin:D"])
            let point = screenPoint(NSPoint(x: old.midX, y: old.minY + 1), in: try #require(controller.window))
            let drop = list.externalHover(at: point, allowsPinned: true, carrying: .bookmark(favorite.id))
            let resolved = try #require(drop)
            #expect(resolved.folder == tree.work.id)
            #expect(resolved.index == Library.shared.bookmarks(in: tree.space).firstIndex { $0.id == tree.d.id })
            let line = try #require(list.debugInsertionLineInWindow())
            #expect(abs(line.midY - (old.minY - Tokens.Sidebar.rowGap / 2)) <= 1)
            #expect(abs(line.midY - (d.minY - Tokens.Sidebar.rowGap / 2)) > 1)
            _ = controller.dropFavorite(favorite, at: point, to: list.externalDropTarget)
            #expect(Library.shared.folderID(containing: favorite.id) == tree.work.id)
            let order = Library.shared.bookmarks(in: tree.space).map(\.id)
            #expect(order.firstIndex(of: favorite.id) == order.firstIndex(of: tree.d.id).map { $0 - 1 })
        }
    }

    /// X1 below Docs: the line and the landing are the gap above B, inside Docs.
    @Test func aFavoriteBelowDocsDrawsAndLandsAboveB() throws {
        try withLibrary {
            let tree = try makeTree()
            let profile = Library.shared.profileID(ofSpace: tree.space)
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
            let manager = TabManager(spaceID: tree.space)
            defer { manager.invalidate() }
            let controller = window(manager)
            defer { controller.window?.close() }
            controller.window?.orderFront(nil)
            let list = controller.sidebar.list
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let frames = rows(list)
            let docs = try #require(frames["folder:Docs"])
            let b = try #require(frames["pin:B"])
            let point = screenPoint(NSPoint(x: docs.midX, y: docs.maxY + 1), in: try #require(controller.window))
            let drop = list.externalHover(at: point, allowsPinned: true, carrying: .bookmark(favorite.id))
            let resolved = try #require(drop)
            #expect(resolved.folder == tree.docs.id)
            #expect(resolved.index == Library.shared.bookmarks(in: tree.space).firstIndex { $0.id == tree.b.id })
            let line = try #require(list.debugInsertionLineInWindow())
            #expect(abs(line.midY - (b.minY - Tokens.Sidebar.rowGap / 2)) <= 1)
            _ = controller.dropFavorite(favorite, at: point, to: list.externalDropTarget)
            #expect(Library.shared.folderID(containing: favorite.id) == tree.docs.id)
            let order = Library.shared.bookmarks(in: tree.space).map(\.id)
            #expect(order.firstIndex(of: favorite.id) == order.firstIndex(of: tree.b.id).map { $0 - 1 })
        }
    }

    /// A pinned card dropped at the top level stays a card; inside Work it is demoted to a row there.
    @Test func aCardStaysACardAtTheRootAndBecomesARowInsideAFolder() throws {
        try withLibrary {
            let tree = try makeTree()
            let f = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/f")!, title: "F", to: tree.space))
            let saved = SidebarView.pinnedTabsAsTiles
            defer { SidebarView.pinnedTabsAsTiles = saved }
            SidebarView.pinnedTabsAsTiles = true
            let manager = TabManager(spaceID: tree.space)
            defer { manager.invalidate() }
            let controller = window(manager)
            defer { controller.window?.close() }
            controller.window?.orderFront(nil)
            controller.reloadPinnedTiles()
            controller.sidebar.layoutSubtreeIfNeeded()
            let list = controller.sidebar.list
            let grid = controller.sidebar.pinnedTiles
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let frames = rows(list)
            let first = try #require(frames.values.min { $0.minY < $1.minY })
            let top = screenPoint(NSPoint(x: first.midX, y: first.minY - 2), in: try #require(controller.window))
            _ = grid.onDragMove?(f, top)
            _ = grid.onDrop?(f, top)
            #expect(Library.shared.folderID(containing: f.id) == nil)
            #expect(grid.tileIDs.contains(f.id))
            // Inside Work, in the gap above A.
            let a = try #require(frames["pin:A"])
            let inside = screenPoint(NSPoint(x: a.midX, y: a.minY - 1), in: try #require(controller.window))
            _ = grid.onDragMove?(f, inside)
            _ = grid.onDrop?(f, inside)
            #expect(Library.shared.folderID(containing: f.id) == tree.work.id)
            #expect(!grid.tileIDs.contains(f.id))
            #expect(list.debugRows().contains { $0.0 == "pin:F" })
        }
    }

    /// A pinned card and a tab cross into another window's grids, and a tab moves before it becomes a card.
    @Test func cardsAndTabsMoveIntoAnotherWindowsGrids() throws {
        try withLibrary {
            let tree = try makeTree()
            let f = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/f")!, title: "F", to: tree.space))
            let g = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/g")!, title: "G", to: tree.space))
            let sourceManager = TabManager(spaceID: tree.space)
            let targetManager = TabManager(spaceID: tree.space)
            defer { sourceManager.invalidate(); targetManager.invalidate() }
            let source = window(sourceManager)
            let target = window(targetManager)
            defer { source.window?.close(); target.window?.close() }
            source.window?.orderFront(nil)
            target.window?.orderFront(nil)
            // A pinned card to the other window's favorites.
            target.sidebar.favorites.isDropTarget = true
            _ = target.takePinned(f.id, from: source, at: .zero)
            #expect(Library.shared.isFavorite(f.id))
            // A pinned card to the other window's pinned cards.
            target.sidebar.favorites.isDropTarget = false
            target.sidebar.pinnedTiles.isDropTarget = true
            _ = target.takePinned(g.id, from: source, at: .zero)
            #expect(Library.shared.spaceID(ofBookmark: g.id) == tree.space)
            #expect(Library.shared.isFavorite(g.id) == false)
            // A tab to the other window's favorites, then another to its pinned cards.
            let tab = Tab(url: URL(string: "https://example.com/tab")!, title: "Tab", spaceID: tree.space)
            sourceManager.adopt([tab], in: tree.space)
            #expect(target.listFavoriteTabInWindow(tab, controller: source))
            #expect(targetManager.tab(with: tab.id) === tab || targetManager.bookmarkTab(for: tab.bookmarkID ?? UUID()) != nil)
            let tab2 = Tab(url: URL(string: "https://example.com/tab2")!, title: "Tab 2", spaceID: tree.space)
            sourceManager.adopt([tab2], in: tree.space)
            target.sidebar.favorites.isDropTarget = false
            target.sidebar.pinnedTiles.isDropTarget = true
            #expect(target.listPinTabInWindowToTiles(tab2, from: source))
            #expect(targetManager.bookmarkTab(for: tab2.bookmarkID ?? UUID()) != nil)
        }
    }

    /// A card over a shut folder lights it, flashes twice and opens it after the 0.8 second wait.
    @Test func aCardOverAShutFolderFlashesTwiceThenOpensIt() async throws {
        let saved = Library.shared.snapshot
        defer { Library.shared.restore(saved) }
        do {
            let tree = try makeTree()
            Library.shared.setFolderOpen(tree.old.id, false)
            let profile = Library.shared.profileID(ofSpace: tree.space)
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
            let manager = TabManager(spaceID: tree.space)
            defer { manager.invalidate() }
            let controller = window(manager)
            defer { controller.window?.close() }
            controller.window?.orderFront(nil)
            let list = controller.sidebar.list
            list.reload(animated: false)
            list.layoutSubtreeIfNeeded()
            let oldFrame = try #require(rows(list)["folder:Old"])
            let point = screenPoint(NSPoint(x: oldFrame.midX, y: oldFrame.midY), in: try #require(controller.window))
            _ = list.externalHover(at: point, allowsPinned: true, carrying: .bookmark(favorite.id))
            let row = try #require(list.folderRow(tree.old.id) as? FolderRowView)
            #expect(!row.isDropTarget)
            try await Task.sleep(for: .milliseconds(120))
            #expect(row.isDropTarget)
            #expect(row.debugDropFlashes == 2)
            try await Task.sleep(for: .milliseconds(900))
            #expect(Library.shared.folder(tree.old.id)?.isOpen == true)
        }
    }

    /// A folder opened by the drag closes when the pointer leaves it for another folder. The folder that holds the
    /// new pointer stays open, and so does the folder a drop lands in.
    @Test func aFolderOpenedByTheDragClosesWhenThePointerLeavesIt() async throws {
        let saved = Library.shared.snapshot
        defer { Library.shared.restore(saved) }
        let tree = try makeTree()
        Library.shared.setFolderOpen(tree.work.id, false)
        Library.shared.setFolderOpen(tree.docs.id, false)
        let profile = Library.shared.profileID(ofSpace: tree.space)
        let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
        let manager = TabManager(spaceID: tree.space)
        defer { manager.invalidate() }
        let controller = window(manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        let list = controller.sidebar.list
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        func point(_ name: String, y: CGFloat? = nil) throws -> NSPoint {
            let frame = try #require(rows(list)[name])
            return screenPoint(NSPoint(x: frame.midX, y: y ?? frame.midY), in: window)
        }

        _ = list.externalHover(at: try point("folder:Work"), allowsPinned: true, carrying: .bookmark(favorite.id))
        try await Task.sleep(for: .milliseconds(1000))
        #expect(Library.shared.folder(tree.work.id)?.isOpen == true)
        _ = list.externalHover(at: try point("folder:Docs"), allowsPinned: true, carrying: .bookmark(favorite.id))
        try await Task.sleep(for: .milliseconds(1000))
        #expect(Library.shared.folder(tree.docs.id)?.isOpen == true)

        // The gap above A is inside Work but outside Docs. Docs closes, Work stays.
        let a = try #require(rows(list)["pin:A"])
        _ = list.externalHover(at: screenPoint(NSPoint(x: a.midX, y: a.minY - 1), in: window),
                               allowsPinned: true, carrying: .bookmark(favorite.id))
        #expect(Library.shared.folder(tree.docs.id)?.isOpen == false)
        #expect(Library.shared.folder(tree.work.id)?.isOpen == true)

        let drop = try #require(list.externalDropTarget)
        #expect(drop.folder == tree.work.id)
        list.externalDragFinished(keeping: drop)
        #expect(Library.shared.folder(tree.work.id)?.isOpen == true)
    }

    /// A folder a canceled drag opened closes again. The landing path keeps the folder it lands in.
    @Test func aCancelledDragClosesTheFolderItOpened() async throws {
        let saved = Library.shared.snapshot
        defer { Library.shared.restore(saved) }
        let tree = try makeTree()
        Library.shared.setFolderOpen(tree.old.id, false)
        let profile = Library.shared.profileID(ofSpace: tree.space)
        let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
        let manager = TabManager(spaceID: tree.space)
        defer { manager.invalidate() }
        let controller = window(manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        let list = controller.sidebar.list
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let old = try #require(rows(list)["folder:Old"])
        _ = list.externalHover(at: screenPoint(NSPoint(x: old.midX, y: old.midY), in: window),
                               allowsPinned: true, carrying: .bookmark(favorite.id))
        try await Task.sleep(for: .milliseconds(1000))
        #expect(Library.shared.folder(tree.old.id)?.isOpen == true)
        list.externalDragFinished(keeping: nil)
        #expect(Library.shared.folder(tree.old.id)?.isOpen == false)
    }

    /// A folder open before the drag is never in the ledger, so moving away leaves it open.
    @Test func aFolderAlreadyOpenStaysOpenWhenTheDragMovesOn() async throws {
        let saved = Library.shared.snapshot
        defer { Library.shared.restore(saved) }
        let tree = try makeTree()
        Library.shared.setFolderOpen(tree.work.id, true)
        Library.shared.setFolderOpen(tree.docs.id, false)
        let profile = Library.shared.profileID(ofSpace: tree.space)
        let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
        let manager = TabManager(spaceID: tree.space)
        defer { manager.invalidate() }
        let controller = window(manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        let list = controller.sidebar.list
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        func point(_ name: String) throws -> NSPoint {
            let frame = try #require(rows(list)[name])
            return screenPoint(NSPoint(x: frame.midX, y: frame.midY), in: window)
        }

        _ = list.externalHover(at: try point("folder:Work"), allowsPinned: true, carrying: .bookmark(favorite.id))
        try await Task.sleep(for: .milliseconds(150))
        _ = list.externalHover(at: try point("folder:Docs"), allowsPinned: true, carrying: .bookmark(favorite.id))
        try await Task.sleep(for: .milliseconds(1000))
        #expect(Library.shared.folder(tree.docs.id)?.isOpen == true)
        #expect(Library.shared.folder(tree.work.id)?.isOpen == true)
        list.externalDragFinished(keeping: nil)
        #expect(Library.shared.folder(tree.docs.id)?.isOpen == false)
        #expect(Library.shared.folder(tree.work.id)?.isOpen == true)
    }

    /// A fast sweep across shut folders lights none of the rows it crosses. The landing is the last folder at once;
    /// the fill waits for the rest, then the one folder left behind flashes twice and opens. A row left behind goes
    /// dark at once, with no fade or flash still running.
    @Test func aFastSweepLightsOnlyTheFolderItStopsOn() async throws {
        let saved = Library.shared.snapshot
        defer { Library.shared.restore(saved) }
        let tree = try makeTree()
        let names = ["Library", "Java", "Web", "Linux", "Saved 2", "Saved 3", "Saved 4"]
        var folders: [(id: UUID, name: String)] = []
        for name in names {
            let page = try #require(Library.shared.addBookmark(
                url: URL(string: "https://example.com/\(UUID().uuidString)")!, title: name + " page", to: tree.space))
            let folder = try #require(Library.shared.addFolder(named: name, with: [page.id], in: tree.space))
            Library.shared.setFolderOpen(folder.id, false)
            folders.append((folder.id, name))
        }
        let profile = Library.shared.profileID(ofSpace: tree.space)
        let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
        let manager = TabManager(spaceID: tree.space)
        defer { manager.invalidate() }
        let controller = window(manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        let list = controller.sidebar.list
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        let frames = rows(list)
        let ordered = folders.compactMap { folder -> (id: UUID, name: String, frame: NSRect)? in
            frames["folder:" + folder.name].map { (folder.id, folder.name, $0) }
        }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(ordered.count == names.count)
        let window = try #require(controller.window)

        // The whole sweep lands in one turn of the run loop, as a quick hand moves it: no row waits long enough to
        // light while the pointer crosses it.
        for folder in ordered {
            let row = try #require(list.folderRow(folder.id))
            _ = list.externalHover(at: point(of: row, in: window), allowsPinned: true, carrying: .bookmark(favorite.id))
        }
        let last = try #require(ordered.last)
        #expect(list.externalDropTarget?.folder == last.id)
        for folder in ordered {
            #expect((list.folderRow(folder.id) as? FolderRowView)?.isDropTarget == false, "\(folder.name)")
        }

        try await Task.sleep(for: .milliseconds(120))
        for folder in ordered {
            let row = try #require(list.folderRow(folder.id) as? FolderRowView)
            #expect(row.isDropTarget == (folder.id == last.id), "\(folder.name)")
            if folder.id != last.id { #expect(row.debugDropFlashes == 0, "\(folder.name) flashed") }
        }
        let lastRow = try #require(list.folderRow(last.id) as? FolderRowView)
        #expect(lastRow.debugDropFlashes == 2)
        #expect(!lastRow.debugDropAnimations.isEmpty)

        // Leaving it for another folder clears it at once: no fill, no flash, still running.
        let first = try #require(ordered.first)
        let firstView = try #require(list.folderRow(first.id))
        _ = list.externalHover(at: point(of: firstView, in: window), allowsPinned: true, carrying: .bookmark(favorite.id))
        #expect(!lastRow.isDropTarget)
        #expect(lastRow.debugDropAnimations.isEmpty)

        try await Task.sleep(for: .milliseconds(120))
        let firstRow = try #require(list.folderRow(first.id) as? FolderRowView)
        #expect(firstRow.isDropTarget)
        #expect(firstRow.debugDropFlashes == 2)
        try await Task.sleep(for: .milliseconds(900))
        #expect(Library.shared.folder(first.id)?.isOpen == true)
    }

    /// Numbers show on favorites only: not on pinned cards, pinned rows or tabs.
    @Test func numbersShowOnFavoritesOnly() throws {
        try withLibrary {
            let tree = try makeTree()
            let root = try #require(Library.shared.addBookmark(url: URL(string: "https://example.com/root")!, title: "Root", to: tree.space))
            let profile = Library.shared.profileID(ofSpace: tree.space)
            let favorite = Library.shared.addFavorite(url: URL(string: "https://example.com/x1")!, title: "X1", in: profile)
            let saved = SidebarView.pinnedTabsAsTiles
            defer { SidebarView.pinnedTabsAsTiles = saved }
            SidebarView.pinnedTabsAsTiles = true
            let manager = TabManager(spaceID: tree.space)
            defer { manager.invalidate() }
            let tab = Tab(url: URL(string: "https://example.com/tab")!, title: "Tab", spaceID: tree.space)
            manager.adopt([tab], in: tree.space)
            let controller = window(manager)
            defer { controller.window?.close() }
            controller.window?.orderFront(nil)
            controller.reloadPinnedTiles()
            controller.sidebar.layoutSubtreeIfNeeded()
            controller.numberHints?.show(force: true)
            let favoriteTile = try #require(controller.sidebar.favorites.tile(for: favorite.id) as? FavoriteTile)
            #expect(favoriteTile.number != nil)
            let pinnedTile = try #require(controller.sidebar.pinnedTiles.tile(for: root.id) as? FavoriteTile)
            #expect(pinnedTile.number == nil)
            let pinnedRow = try #require(controller.sidebar.list.row(forBookmark: tree.e.id) as? TabRowView)
            #expect(pinnedRow.number == nil)
            let tabRow = try #require(controller.sidebar.list.row(for: tab) as? TabRowView)
            #expect(tabRow.number == nil)
        }
    }
}
