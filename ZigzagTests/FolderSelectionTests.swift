import AppKit
import Testing
@testable import Zigzag

/// Picking folders with the other rows, and carrying them: the rows a picked folder takes with it, the order a whole
/// selection lands in, and the one place transaction that moves it. The cases are the ones in
/// docs/plans/sidebar-bulk-folders.md, without a window or a pointer.
@MainActor
struct FolderSelectionTests {
    // MARK: Selection

    /// A folder is a row that can be picked, and it is still not a page: the numbers and ⌘1–⌘9 count pages only.
    @Test func aFolderIsPickableButNotAPageRow() {
        let folder = SidebarItem.folder(UUID())
        #expect(folder.isPickable)
        #expect(!folder.isPageRow)
        #expect(SidebarItem.bookmark(UUID()).isPickable)
        #expect(SidebarItem.tab(UUID()).isPickable)
        #expect(!SidebarItem.header.isPickable)
        #expect(!SidebarItem.newTab.isPickable)
    }

    /// ⇧-click over folders and pages keeps the list's order, and a picked folder leaves its own pages and subfolders
    /// out of the selection: the folder carries them.
    @Test func shiftClickKeepsListOrderAndLeavesAFoldersRowsToIt() throws {
        let tree = PinnedDropFixture.standard()
        let all = tree.rows.map(\.item)
        let empty = SidebarItem.folder(try tree.folderID("Empty"))
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let shut = SidebarItem.folder(try tree.folderID("Shut"))
        let f = SidebarItem.bookmark(try tree.pageID("F"))
        let a = SidebarItem.bookmark(try tree.pageID("A"))

        let picked = SidebarListView.markedRows([], clicking: f, anchor: empty, extending: true, all: all, folders: tree.folders)
        #expect(picked == [empty, work, reading, shut, f])
        #expect(!picked.contains(a))
        for offset in 1..<picked.count {
            let previous = try #require(all.firstIndex(of: picked[offset - 1]))
            let next = try #require(all.firstIndex(of: picked[offset]))
            #expect(previous < next)
        }
    }

    /// Picking a folder takes its pages and subfolders out of the carried rows, at any depth, and keeps the rest in
    /// list order.
    @Test func aPickedFolderRemovesItsPagesAndSubfolders() throws {
        let tree = PinnedDropFixture.standard()
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let docs = SidebarItem.folder(try tree.folderID("Docs"))
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        let b = SidebarItem.bookmark(try tree.pageID("B"))
        let f = SidebarItem.bookmark(try tree.pageID("F"))

        let picked = PickedRows.normalized([work, a, docs, b, f], folders: tree.folders)
        #expect(picked == [work, f])
    }

    /// A page picked inside a picked folder is carried by the folder, so it leaves the selection.
    @Test func aPickedPageInsideAPickedFolderIsRemoved() throws {
        let tree = PinnedDropFixture.standard()
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        #expect(PickedRows.normalized([work, a], folders: tree.folders) == [work])
    }

    /// One click on one row picks it, whatever kind it is, so the first ⌘-click shows what it picked.
    @Test func onePickedRowIsMarked() throws {
        let tree = PinnedDropFixture.standard()
        let all = tree.rows.map(\.item)
        let folder = SidebarItem.folder(try tree.folderID("Work"))
        let page = SidebarItem.bookmark(try tree.pageID("F"))
        for item in [folder, page] {
            let marked = SidebarListView.markedRows([], clicking: item, anchor: nil, extending: false,
                                                    all: all, folders: tree.folders)
            #expect(marked == [item])
        }
    }

    /// Around the row under the pointer: the rows above it, nearest first, and the rows below, nearest first.
    @Test func theRowsAroundThePrimaryKeepTheirOrder() throws {
        let tree = PinnedDropFixture.standard()
        let work = SidebarItem.folder(try tree.folderID("Work"))
        let a = SidebarItem.bookmark(try tree.pageID("A"))
        let f = SidebarItem.bookmark(try tree.pageID("F"))
        let reading = SidebarItem.folder(try tree.folderID("Reading"))
        let picked = [work, a, f, reading]

        let (before, after) = PickedRows.around(picked, primary: f)
        #expect(before == [a, work])
        #expect(after == [reading])
    }

    // MARK: Moving

    /// A folder never lands in itself. The one place transaction refuses it and leaves the tree as it was.
    @Test func aFolderDroppedIntoItselfIsRefused() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A")
        let folder = tree.folder("Folder", holding: [a])
        let place = tree.place
        let drop = SidebarDrop(section: .bookmarks, index: 0, folder: folder, place: .onto(.folder(folder)))
        #expect(place.moved(.folder(folder), to: drop) == nil)
        #expect(place == tree.place)
    }

    /// A picked folder whose destination is inside it is skipped, and the rest of the selection still moves.
    @Test func aFolderIntoItsSubfolderIsSkippedAndTheRestMoves() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A")
        let folder = tree.folder("Folder", holding: [a])
        let sub = tree.folder("Sub", parent: folder)
        let p = tree.page("P")
        let place = tree.place
        let drop = SidebarDrop(section: .bookmarks, index: place.pages.count, folder: sub, place: .onto(.folder(sub)))

        let after = try #require(place.moved([.folder(folder), .bookmark(p)], around: .bookmark(p), to: drop))
        #expect(after.folders.first { $0.id == folder }?.parentID == nil)
        #expect(after.line.folder(containing: p) == sub)
        #expect(after.pages.contains(p))
        #expect(after.pages.contains(a))
    }

    /// A picked folder moves with every page inside it and every folder inside it, as one block.
    @Test func aFolderMovesWithItsWholeSubtree() throws {
        var tree = PinnedDropFixture()
        let x = tree.page("X"), y = tree.page("Y"), z = tree.page("Z")
        let folder = tree.folder("Folder", holding: [x, y])
        let sub = tree.folder("Sub", parent: folder, holding: [z])
        let p = tree.page("P")
        // The folder's row sits above its pages; P is below the whole block.
        #expect(tree.names() == ["[Folder]", "X", "Y", "[Sub]", "Z", "P"])

        #expect(tree.apply(.folder(folder), at: try tree.point(in: .bookmark(p), .below, x: 0)))
        #expect(tree.names() == ["P", "[Folder]", "X", "Y", "[Sub]", "Z"])
        #expect(tree.folders.first { $0.id == sub }?.parentID == folder)
        #expect(Set(tree.folders.pages(in: folder)) == [x, y, z])
    }

    /// One folder through the bulk transaction is the ordinary single move: it lands at the drop, not nothing. The
    /// cross-window path uses this call for a lone folder.
    @Test func oneFolderMovesThroughTheBulkTransaction() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), p = tree.page("P")
        let folder = tree.folder("Folder", holding: [a])
        let place = tree.place
        let drop = SidebarDrop(section: .bookmarks, index: place.pages.count, folder: nil,
                               place: .gap(above: place.line.children(of: nil).last, below: nil, depth: 0))
        let after = try #require(place.moved([.folder(folder)], around: .folder(folder), to: drop))
        #expect(after.pages.count == place.pages.count)
        #expect(after.line.children(of: nil).last == .folder(folder))
        #expect(after.line.folder(containing: a) == folder)
    }

    /// A picked folder and a picked page land in the order the sidebar draws them, around the row under the pointer.
    @Test func aFolderAndAPageLandInListOrderAroundThePrimary() throws {
        var tree = PinnedDropFixture()
        let a = tree.page("A"), b = tree.page("B"), p = tree.page("P")
        let folder = tree.folder("Folder", holding: [a])
        tree.folder("Target", holding: [b])
        let target = try tree.folderID("Target")
        #expect(tree.names() == ["[Folder]", "A", "[Target]", "B", "P"])

        let place = tree.place
        let drop = SidebarDrop(section: .bookmarks, index: 2, folder: target, place: .onto(.folder(target)))
        let after = try #require(place.moved([.folder(folder), .bookmark(p)], around: .bookmark(p), to: drop))
        let children = after.line.children(of: target)
        // The folder is above the page in the selection, so it goes just before it, still one block with A.
        #expect(children.count == 3)
        #expect(children[1] == .folder(folder))
        #expect(children[2] == .bookmark(p))
        #expect(after.line.folder(containing: a) == folder)
    }
}

/// The library's own bulk move: one snapshot takes back every picked row, page and folder.
@MainActor
struct FolderSelectionLibraryTests {
    @Test func oneSnapshotRestoresEveryPickedRow() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Folder Selection").id
        let other = Library.shared.addSpace(name: "Folder Selection Other").id
        let pages = Library.shared.appendBookmarks(
            [
                (URL(string: "http://127.0.0.1:9/a")!, "A"),
                (URL(string: "http://127.0.0.1:9/b")!, "B"),
                (URL(string: "http://127.0.0.1:9/c")!, "C"),
                (URL(string: "http://127.0.0.1:9/d")!, "D"),
                (URL(string: "http://127.0.0.1:9/e")!, "E"),
                (URL(string: "http://127.0.0.1:9/f")!, "F"),
            ],
            to: space,
            folders: [["Box"], ["Target"], ["Box"], ["Target"], [], []])
        let box = try #require(Library.shared.folders(in: space).first { $0.name == "Box" })
        let target = try #require(Library.shared.folders(in: space).first { $0.name == "Target" })
        let a = pages[0].id, c = pages[2].id
        #expect(Set(Library.shared.allBookmarkIDs(inFolder: box.id)) == [a, c])
        let p = pages[4].id
        let beforeSpace = try #require(Library.shared.space(space))
        let beforeOther = try #require(Library.shared.space(other))
        // The snapshot just before the move: restoring it is what one undo does, with every picked row in it.
        let beforeMove = Library.shared.snapshot

        let drop = SidebarDrop(section: .bookmarks, index: 0, folder: target.id, place: .onto(.folder(target.id)))
        #expect(Library.shared.movePicked([.folder(box.id), .bookmark(p)], around: .bookmark(p), to: drop, in: space))
        let moved = try #require(Library.shared.space(space))
        #expect(moved != beforeSpace)
        #expect(Library.shared.allBookmarkIDs(inFolder: box.id) == [a, c])
        #expect(Library.shared.folder(box.id)?.parentID == target.id)
        #expect(Library.shared.folderID(containing: p) == target.id)
        #expect(Library.shared.space(other) == beforeOther)

        Library.shared.restore(beforeMove)
        #expect(Library.shared.space(space) == beforeSpace)
    }
}

/// The folder row's own click: ⌘-click and ⇧-click pick it, a plain click still opens or shuts it. The selection rules
/// above can be right while the row never asks them, so this drives the row's closure as a click does.
@MainActor
struct FolderRowClickTests {
    private final class Host: SidebarListDelegate {
        let tabManager: TabManager
        /// The menu a right-click returns; nil when a test doesn't need one.
        var rowMenu: NSMenu?
        init(_ manager: TabManager) { tabManager = manager }
        func listSelect(_ tab: Tab) {}
        func listOpenBookmark(_ bookmark: Bookmark) {}
        func listRenameBookmark(_ id: UUID, to name: String) {}
        func listClose(_ tab: Tab) {}
        func listClose(_ tabs: [Tab]) {}
        func listRemove(_ items: [SidebarItem]) {}
        func listNewTab() {}
        func listClearTabs() {}
        func listSetFolderOpen(_ id: UUID, _ open: Bool) {}
        func listSetGroupOpen(_ id: UUID, _ open: Bool) {}
        func listRenameGroup(_ id: UUID, to name: String) {}
        func listMoveGroup(_ id: UUID, to index: Int, in spaceID: UUID) {}
        func listPinGroup(_ id: UUID, at index: Int, in spaceID: UUID, folder: UUID?) {}
        func listAddToGroup(_ tabs: [Tab], group: UUID) {}
        func listRenameFolder(_ id: UUID, to name: String) {}
        func listSetFolder(of bookmarkID: UUID, to folderID: UUID?) {}
        func listAsOne(_ name: String, _ body: @escaping () -> Void) { body() }
        func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?) {}
        func listMovePinned(_ item: SidebarItem, to drop: SidebarDrop, in spaceID: UUID) {}
        func listMovePicked(_ items: [SidebarItem], around dragged: SidebarItem, to drop: SidebarDrop, in spaceID: UUID) {}
        func listMoveFolder(_ id: UUID, to index: Int, in spaceID: UUID, parent: UUID?) {}
        func listHover(_ tab: Tab?, row: NSView?, bookmark: Bookmark?) {}
        func listMenu(for item: SidebarItem) -> NSMenu? { rowMenu }
        func listMenu(forMarked items: [SidebarItem]) -> NSMenu? { nil }
        func listDragHoverSpace(at windowPoint: NSPoint) -> UUID? { nil }
        func listDragEnded() {}
        func listDropFinished() {}
        func listMove(_ tab: Tab, to index: Int, in spaceID: UUID, nesting: TabManager.Nesting, grouping: TabManager.Grouping) {}
        func listBookmark(_ tab: Tab, at index: Int, in spaceID: UUID) {}
        func listUnbookmark(_ bookmarkID: UUID, to index: Int, under parent: UUID?, group: UUID?) {}
        func listSetNestedTabsCollapsed(_ tab: Tab, _ collapsed: Bool) {}
        func listSwitchSpaceDuringDrag(_ spaceID: UUID) {}
        func listDropOutside(_ tabs: [Tab], at screenPoint: NSPoint) -> Bool { false }
        func listMoveToWindow(_ tabs: [Tab], controller: BrowserWindowController, index: Int) -> Bool { false }
        func listMovePinnedToWindow(_ bookmarkID: UUID, controller: BrowserWindowController, to drop: SidebarDrop?, at screenPoint: NSPoint) -> NSView? { nil }
        func listMoveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {}
        func listDragOverFavorites(at windowPoint: NSPoint?, carrying: TabManager.SplitSide?) -> Bool { false }
        func listSplit(_ tab: Tab, with other: Tab, otherOnRight: Bool) {}
        func listJoinSplit(_ page: TabManager.RowPage, onto target: TabManager.RowPage, onRight: Bool) {}
        func listZoomPane(_ tab: Tab) {}
        func listPinSplit(_ tab: Tab, onto bookmarkID: UUID, tabOnRight: Bool) {}
        func listUnpinSplit(_ bookmarkID: UUID, onto tab: Tab, pinnedOnRight: Bool) {}
        func listJoinPinned(_ bookmarkID: UUID, onto targetID: UUID, onRight: Bool) {}
        func listDropOnFavorites(_ items: [SidebarItem], dragged: SidebarItem) -> Bool { false }
        func listFavoriteTile(for bookmarkID: UUID) -> NSView? { nil }
        func listDragOverPage(at windowPoint: NSPoint?, item: SidebarItem) {}
        func listDropOnPage(_ item: SidebarItem) -> Bool { false }
    }

    private func commandClick() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .command, timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func commandClickingFolderRowsPicksThem() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Folder Row Click").id
        _ = Library.shared.appendBookmarks(
            [(URL(string: "http://127.0.0.1:9/one")!, "One page"),
             (URL(string: "http://127.0.0.1:9/two")!, "Two page"),
             (URL(string: "http://127.0.0.1:9/three")!, "Three page")],
            to: space, folders: [["One"], ["Two"], []])
        let one = try #require(Library.shared.folders(in: space).first { $0.name == "One" }?.id)
        let two = try #require(Library.shared.folders(in: space).first { $0.name == "Two" }?.id)
        let oneWasOpen = Library.shared.folder(one)?.isOpen
        let twoWasOpen = Library.shared.folder(two)?.isOpen
        // No tab in the space: the first ⌘-click has nothing to start from, as in the seeded spaces.
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let host = Host(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        let first = try #require(list.folderRow(one) as? FolderRowView)
        first.onClick?(commandClick())
        // The first click marks the folder straight away.
        #expect(list.marked == [.folder(one)])
        #expect((list.folderRow(one) as? FolderRowView)?.isMarked == true)
        let second = try #require(list.folderRow(two) as? FolderRowView)
        second.onClick?(commandClick())
        #expect(list.marked.contains(.folder(one)))
        #expect(list.marked.contains(.folder(two)))
        // The rows draw the mark, not only the selection holding them.
        #expect((list.folderRow(one) as? FolderRowView)?.isMarked == true)
        #expect((list.folderRow(two) as? FolderRowView)?.isMarked == true)
        // The click picked the folders; it did not open or shut them.
        #expect(Library.shared.folder(one)?.isOpen == oneWasOpen)
        #expect(Library.shared.folder(two)?.isOpen == twoWasOpen)
    }

    /// A tab row shows its mark on the first ⌘-click too, as a folder does.
    @Test func commandClickingATabRowMarksItOnTheFirstClick() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Tab Row Click").id
        let manager = TabManager(spaceID: space)
        let tab = manager.newTab(url: nil, spaceID: space, select: true)
        defer { tab.close(); manager.invalidate() }
        let host = Host(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        let row = try #require(list.tabRow(tab.id) as? TabRowView)
        row.onClick?(commandClick())
        #expect(list.marked == [.tab(tab.id)])
        #expect(row.isMarked)
    }

    /// The page you are on is not part of a ⌘-click pick. It used to be added as the selection started, so a split
    /// row nobody picked followed the folders and landed with them.
    @Test func commandClickingFoldersDoesNotPickTheCurrentRow() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Folder Row Current").id
        _ = Library.shared.appendBookmarks(
            [(URL(string: "http://127.0.0.1:9/one")!, "One page"),
             (URL(string: "http://127.0.0.1:9/two")!, "Two page")],
            to: space, folders: [["One"], ["Two"]])
        let one = try #require(Library.shared.folders(in: space).first { $0.name == "One" }?.id)
        let two = try #require(Library.shared.folders(in: space).first { $0.name == "Two" }?.id)
        let manager = TabManager(spaceID: space)
        let tab = manager.newTab(url: nil, spaceID: space, select: true)
        defer { tab.close(); manager.invalidate() }
        let host = Host(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        (list.folderRow(one) as? FolderRowView)?.onClick?(commandClick())
        (list.folderRow(two) as? FolderRowView)?.onClick?(commandClick())
        #expect(list.marked == [.folder(one), .folder(two)])
        #expect(!list.marked.contains(.tab(tab.id)))
    }

    /// One picked row keeps its mark while its menu is open: an action keeps it, so the next one acts on the same
    /// row, and a menu closed with no action lets it go. A right-click away from the pick lets go at once.
    @Test func aSingleMarkStaysWhileItsMenuIsOpen() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Folder Menu Mark").id
        _ = Library.shared.appendBookmarks([(URL(string: "http://127.0.0.1:9/menu-a")!, "Menu page"),
                                            (URL(string: "http://127.0.0.1:9/menu-b")!, "Menu page two")],
                                           to: space, folders: [["One"], ["Two"]])
        let one = try #require(Library.shared.folders(in: space).first { $0.name == "One" }?.id)
        let two = try #require(Library.shared.folders(in: space).first { $0.name == "Two" }?.id)
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let host = Host(manager)
        let menu = NSMenu(title: "Row")
        menu.addItem(NSMenuItem(title: "Rename", action: nil, keyEquivalent: ""))
        host.rowMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        (list.folderRow(one) as? FolderRowView)?.onClick?(commandClick())
        #expect(list.marked == [.folder(one)])

        // Open the menu: the one mark stays.
        let row = try #require(list.folderRow(one) as? FolderRowView)
        _ = row.onRightClick?(rightClick())
        #expect(list.marked == [.folder(one)])
        // An action chosen from it keeps the mark.
        list.menuClosed(choseAction: true)
        #expect(list.marked == [.folder(one)])
        // Dismissed with no action, the mark goes.
        _ = row.onRightClick?(rightClick())
        #expect(list.marked == [.folder(one)])
        list.menuClosed(choseAction: false)
        #expect(list.marked.isEmpty)
        // A right-click on a row that is not the pick lets it go at once.
        (list.folderRow(one) as? FolderRowView)?.onClick?(commandClick())
        #expect(list.marked == [.folder(one)])
        (list.folderRow(two) as? FolderRowView)?.onRightClick?(rightClick())
        #expect(list.marked.isEmpty)
    }

    /// A single marked tab keeps its mark through its menu, and Esc lets it go: the row the user picks first is often
    /// the tab already showing, whose card used to cover the mark.
    @Test func aSingleTabMarkStaysThroughItsMenuAndEscLetsItGo() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Tab Menu Mark").id
        let manager = TabManager(spaceID: space)
        let tab = manager.newTab(url: nil, spaceID: space, select: true)
        defer { tab.close(); manager.invalidate() }
        let host = Host(manager)
        let menu = NSMenu(title: "Row")
        menu.addItem(NSMenuItem(title: "Rename", action: nil, keyEquivalent: ""))
        host.rowMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        let row = try #require(list.tabRow(tab.id) as? TabRowView)
        row.onClick?(commandClick())
        #expect(list.marked == [.tab(tab.id)])
        #expect(list.acceptsFirstResponder)
        _ = row.onRightClick?(rightClick())
        #expect(list.marked == [.tab(tab.id)])
        list.menuClosed(choseAction: true)
        #expect(list.marked == [.tab(tab.id)])

        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        list.keyDown(with: esc)
        #expect(list.marked.isEmpty)
    }

    /// A pinned page and a folder from elsewhere resolve against this list's pinned rows, the line's value and the
    /// drop's value being the one `SidebarDrop`.
    @Test func aPinnedPageAndAFolderFromElsewhereResolveInThisList() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "External Hover").id
        let pages = Library.shared.appendBookmarks(
            [(URL(string: "http://127.0.0.1:9/hover/a")!, "A"),
             (URL(string: "http://127.0.0.1:9/hover/b")!, "B")],
            to: space, folders: [["Work"], []])
        let work = try #require(Library.shared.folders(in: space).first { $0.name == "Work" }?.id)
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let host = Host(manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(list)
        list.delegate = host
        list.reload(animated: false)

        func screenPoint(of view: NSView, y: CGFloat? = nil) -> NSPoint {
            window.convertPoint(toScreen: view.convert(NSPoint(x: 20, y: y ?? view.bounds.midY), to: nil))
        }

        // A page at the top level is always a row: a shut folder can hide the one inside it. The gap above the row
        // is the seam to aim at: the row's own middle is where the carried row sits, and takes nothing.
        let pageRow = try #require(list.bookmarkRow(pages[1].id))
        let page = list.externalHover(at: screenPoint(of: pageRow, y: -2), allowsPinned: true, carrying: .bookmark(pages[1].id))
        #expect(page?.section == .bookmarks)
        #expect(list.externalDropTarget == page)
        list.externalHover(at: nil)

        let folderRow = try #require(list.folderRow(work))
        let folder = list.externalHover(at: screenPoint(of: folderRow, y: -2), allowsPinned: true, carrying: .folder(work))
        #expect(folder?.section == .bookmarks)
        #expect(list.externalDropTarget == folder)
        list.externalHover(at: nil)
    }
}
