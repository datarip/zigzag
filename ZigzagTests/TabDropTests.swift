import AppKit
import Testing
@testable import Zigzag

/// The tab tree the tab drop resolver is tested against. It has nested tabs two levels deep, a tab group with two tabs,
/// and top-level tabs either side. The rows are laid out the way the list lays them out, so a test can place a pointer
/// by row and band. The resolver takes a small tree, with no window and no `TabManager`.
@MainActor
struct TabDropFixture {
    struct Tab {
        let id: UUID
        let title: String
        var parent: UUID?
        var group: UUID?
    }

    private(set) var tabs: [Tab] = []
    private(set) var groups: [TabGroup] = []
    private let width: CGFloat = 240

    // MARK: Building

    @discardableResult
    mutating func tab(_ title: String, under parent: UUID? = nil, group: UUID? = nil) -> UUID {
        let id = UUID()
        tabs.append(Tab(id: id, title: title, parent: parent, group: group))
        return id
    }

    @discardableResult
    mutating func group(_ name: String, open: Bool = true) -> UUID {
        let group = TabGroup(name: name, isOpen: open)
        groups.append(group)
        return group.id
    }

    /// A, with A1 under it and A1a under that. B sits next. Team's tabs T1 and T2 follow. Then C.
    static func standard() -> TabDropFixture {
        var tree = TabDropFixture()
        let a = tree.tab("A")
        let a1 = tree.tab("A1", under: a)
        tree.tab("A1a", under: a1)
        tree.tab("B")
        let team = tree.group("Team")
        tree.tab("T1", group: team)
        tree.tab("T2", group: team)
        tree.tab("C")
        return tree
    }

    // MARK: Lookups

    func tabID(_ title: String) throws -> UUID { try #require(tabs.first { $0.title == title }?.id) }

    func groupID(_ name: String) throws -> UUID { try #require(groups.first { $0.name == name }?.id) }

    func row(_ item: SidebarItem) throws -> DropRow { try #require(shown.rows.first { $0.item == item }) }

    // MARK: What the list shows

    var nodes: [TabTree.Node] { tabs.map { TabTree.Node(id: $0.id, parent: $0.parent) } }

    var groupOf: [UUID: UUID] {
        Dictionary(tabs.compactMap { tab in tab.group.map { (tab.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    var openGroups: [UUID: Bool] {
        Dictionary(groups.map { ($0.id, $0.isOpen) }, uniquingKeysWith: { first, _ in first })
    }

    /// The visible rows, top to bottom. A group row sits at its first tab. Then its tabs and the nested tabs follow,
    /// set in one step per level. `rowTabs` is the tabs each row shows, as a split's row shows both halves.
    var shown: (rows: [DropRow], rowTabs: [[UUID]]) {
        let levels = TabTree.levels(nodes)
        var y: CGFloat = 0
        var rows: [DropRow] = [], rowTabs: [[UUID]] = []
        var shownGroup: UUID?
        for tab in tabs {
            if let group = tab.group, group != shownGroup {
                let item = SidebarItem.tabGroup(group)
                rows.append(DropRow(item: item, frame: NSRect(x: 0, y: y, width: width, height: item.height), depth: 0))
                rowTabs.append(tabs.filter { $0.group == group }.map(\.id))
                y += item.height + Tokens.Sidebar.rowGap
            }
            shownGroup = tab.group
            let depth = (tab.group == nil ? 0 : 1) + TabTree.shownLevel(levels[tab.id] ?? 0)
            let item = SidebarItem.tab(tab.id)
            let inset = SidebarListView.indent(depth: depth)
            rows.append(DropRow(item: item, frame: NSRect(x: inset, y: y, width: width - inset, height: item.height),
                                depth: depth))
            rowTabs.append([tab.id])
            y += item.height + Tokens.Sidebar.rowGap
        }
        return (rows, rowTabs)
    }

    /// A point in one of a row's bands. `above` is its top quarter. `onto` is its middle half. `below` is its bottom
    /// quarter. `x` defaults to the row's own text.
    func point(in item: SidebarItem, _ band: RowBand, x: CGFloat? = nil) throws -> NSPoint {
        let row = try row(item)
        let y: CGFloat = switch band {
        case .above: row.frame.minY + row.frame.height * 0.1
        case .onto: row.frame.midY
        case .below: row.frame.maxY - row.frame.height * 0.1
        }
        return NSPoint(x: x ?? row.frame.minX + SidebarListView.folderIndent, y: y)
    }

    // MARK: What goes with a picked-up row

    /// The rows that leave the list with `item`: a tab takes the tabs under it, a group its tabs.
    func carried(_ item: SidebarItem) -> Set<SidebarItem> {
        var set: Set<SidebarItem> = [item]
        switch item {
        case .tab(let id):
            set.formUnion(TabTree.descendants(of: id, in: nodes).map { .tab($0) })
        case .tabGroup(let id):
            set.formUnion(tabs.filter { $0.group == id }.map { .tab($0.id) })
        default:
            break
        }
        return set
    }

    /// The tabs taken out of the space's list before the drop goes in.
    func moving(_ item: SidebarItem) -> Set<UUID> {
        switch item {
        case .tab(let id): [id]
        case .tabGroup(let id): Set(tabs.filter { $0.group == id }.map(\.id))
        default: []
        }
    }

    /// The snapshot a drag of `item` resolves against. It holds the rows on show, the tabs each shows, the list
    /// without the moving ones, and the tree without the carried ones. The line reads it too, so the test compares both
    /// answers from the same value.
    func snapshot(carrying item: SidebarItem, kind: DragKind? = nil) -> TabDropSnapshot {
        let leaving = carried(item)
        var kept = nodes
        for case .tab(let id) in leaving { kept = TabTree.removing(id, from: kept) }
        let rows = shown
        let resolved: DragKind
        if let kind {
            resolved = kind
        } else {
            resolved = switch item {
            case .folder: .folder
            case .tabGroup: .group
            default: .page
            }
        }
        return TabDropSnapshot(rows: rows.rows, rowTabs: rows.rowTabs,
                               list: tabs.map(\.id).filter { !moving(item).contains($0) },
                               nodes: kept, groups: groupOf, openGroups: openGroups,
                               carried: leaving, kind: resolved, moving: moving(item),
                               takesGroup: { if case .tab = item { true } else { false } }())
    }

    /// The resolver's answer for `item` picked up and the pointer at `point`. `grabbedAt` is the x it was picked up
    /// at, for the two boundary gaps; nil keeps the row rule.
    func drop(_ point: NSPoint, carrying item: SidebarItem, kind: DragKind? = nil,
              grabbedAt: CGFloat? = nil, grabDepth: Int = 0) -> SidebarDrop? {
        snapshot(carrying: item, kind: kind).drop(at: point, grabbedAt: grabbedAt, grabDepth: grabDepth)
    }
}

/// Phase 3: the tab rows resolve with the same rules as the pinned rows. A row's middle is its own offer. Its top and
/// bottom bands are gaps. The line reads the same `SidebarDrop` the drop does.
@MainActor
struct TabDropTests {
    let tree = TabDropFixture.standard()

    /// Picked up C (the last tab) and held over B's top and bottom bands. The gaps are above and below B, at the top
    /// level. Each index is B's or T1's place in the tab list.
    @Test func aTabAboveAndBelowAnotherTab() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let b = SidebarItem.tab(try tree.tabID("B"))
        let team = SidebarItem.tabGroup(try tree.groupID("Team"))
        let a1a = try tree.tabID("A1a")
        let bID = try tree.tabID("B"), t1 = try tree.tabID("T1")
        let above = try #require(tree.drop(try tree.point(in: b, .above, x: 0), carrying: c))
        #expect(above.index == 3)
        #expect(above.place == .gap(above: .tab(a1a), below: b, depth: 0))
        let below = try #require(tree.drop(try tree.point(in: b, .below, x: 0), carrying: c))
        #expect(below.index == 4)
        #expect(below.place == .gap(above: b, below: team, depth: 0))
        // The list positions are B's and T1's, which are the rows either side of the gap.
        #expect(tree.tabs.firstIndex { $0.id == bID } == 3)
        #expect(tree.tabs.firstIndex { $0.id == t1 } == 4)
    }

    /// A tab held between two of a group's tabs joins the group. The gap is at the group's step, in its list place.
    @Test func aTabBetweenAGroupsTabsJoinsTheGroup() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let t1 = SidebarItem.tab(try tree.tabID("T1"))
        let t2 = SidebarItem.tab(try tree.tabID("T2"))
        let t2ID = try tree.tabID("T2"), t1ID = try tree.tabID("T1")
        let drop = try #require(tree.drop(try tree.point(in: t2, .above, x: 0), carrying: c))
        #expect(drop.index == 5)
        #expect(drop.place == .gap(above: t1, below: t2, depth: 1))
        #expect(tree.tabs.firstIndex { $0.id == t1ID } == 4)
        #expect(tree.tabs.firstIndex { $0.id == t2ID } == 5)
    }

    /// Above a group row the gap is at the top level, outside the group. Below it the gap is the group's first slot,
    /// set in at its step. The row's middle takes the tab into the group whole.
    @Test func aTabAboveAndBelowAGroupRow() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let b = SidebarItem.tab(try tree.tabID("B"))
        let team = SidebarItem.tabGroup(try tree.groupID("Team"))
        let t1 = SidebarItem.tab(try tree.tabID("T1"))
        let above = try #require(tree.drop(try tree.point(in: team, .above, x: 0), carrying: c))
        #expect(above.index == 4)
        #expect(above.place == .gap(above: b, below: team, depth: 0))
        let below = try #require(tree.drop(try tree.point(in: team, .below, x: 0), carrying: c))
        #expect(below.index == 4)
        #expect(below.place == .gap(above: team, below: t1, depth: 1))
        let onto = try #require(tree.drop(try tree.point(in: team, .onto), carrying: c))
        #expect(onto.place == .onto(team))
    }

    /// A gap inside a group at its first tab draws under the group's row, above that tab. The group row and its first
    /// tab share one place in the list. Only a gap at the group's own level belongs above the row.
    @Test func aGapInsideAGroupAtItsFirstTabDrawsUnderTheGroupRow() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let team = SidebarItem.tabGroup(try tree.groupID("Team"))
        let t1 = SidebarItem.tab(try tree.tabID("T1"))
        let shown = tree.snapshot(carrying: c)
        let drop = try #require(shown.drop(at: try tree.point(in: t1, .above, x: 0)))
        #expect(drop.place == .gap(above: team, below: t1, depth: 1))
        let line = try #require(shown.line(for: drop, rowGap: Tokens.Sidebar.rowGap))
        let t1Frame = try tree.row(t1).frame, teamFrame = try tree.row(team).frame
        #expect(line.y == t1Frame.minY - Tokens.Sidebar.rowGap / 2)
        #expect(line.y > teamFrame.maxY)
    }

    /// Inside nested tabs the gap goes under the tab above it, one step deeper, whenever the carried row is set in
    /// there. Above A1a with the pointer a step in is under A1, at the second step. Under A1a at the left edge it
    /// leaves the run; a pointer between the run's steps stays under A, the ancestor it is set in under.
    @Test func aNestedTabGap() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let a1 = SidebarItem.tab(try tree.tabID("A1"))
        let a1a = SidebarItem.tab(try tree.tabID("A1a"))
        let a1ID = try tree.tabID("A1")
        let b = SidebarItem.tab(try tree.tabID("B"))
        // Immediately above its first child, a row is already that child's parent: the gap is inside A1.
        let plain = try #require(tree.drop(try tree.point(in: a1a, .above, x: 0), carrying: c))
        #expect(plain.index == 2)
        #expect(plain.place == .gap(above: a1, below: a1a, depth: 2))
        #expect(plain.folder == a1ID)
        let out = try #require(tree.drop(try tree.point(in: a1a, .below, x: 0), carrying: c, grabbedAt: 0))
        #expect(out.place == .gap(above: a1a, below: b, depth: 0))
        // Set in past half a step, the tab stays inside A1, as its last child.
        let setIn = try #require(tree.drop(try tree.point(in: a1a, .below,
                                                          x: SidebarListView.indent(depth: 2) - SidebarListView.folderIndent / 2 + 1),
                                           carrying: c, grabbedAt: 0))
        #expect(setIn.place == .gap(above: a1a, below: b, depth: 2))
        #expect(setIn.folder == a1ID)
        // A level between the two stays under A, the ancestor the carried row is set in under.
        let kept = try #require(tree.drop(try tree.point(in: a1a, .below,
                                                        x: SidebarListView.indent(depth: 2) - SidebarListView.folderIndent / 2 - 1),
                                          carrying: c, grabbedAt: 0))
        #expect(kept.place == .gap(above: a1a, below: b, depth: 1))
        let aID = try tree.tabID("A")
        #expect(kept.folder == aID)
    }

    /// A tab held over another tab's middle is the split offer, not a gap. Its index is still the gap the tab would
    /// fall back to. The line shows there when no split is offered.
    @Test func aTabOverAnotherTabsMiddleOffersASplit() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let b = SidebarItem.tab(try tree.tabID("B"))
        let shown = tree.snapshot(carrying: c)
        let drop = try #require(shown.drop(at: try tree.point(in: b, .onto)))
        #expect(drop.place == .onto(b))
        #expect(drop.index == 3)
        let line = try #require(shown.line(for: drop, rowGap: Tokens.Sidebar.rowGap))
        let frame = try tree.row(b).frame
        #expect(line.y == frame.minY - Tokens.Sidebar.rowGap / 2)
        #expect(line.depth == 0)
    }

    /// A folder never resolves among the tabs. The tab resolver leaves it to the pinned rows, so a folder held over a
    /// tab row lands nowhere there.
    @Test func aFolderDragOverTheTabsDoesNotLandThere() throws {
        let folder = SidebarItem.folder(UUID())
        let b = SidebarItem.tab(try tree.tabID("B"))
        #expect(tree.drop(try tree.point(in: b, .onto), carrying: folder, kind: .folder) == nil)
        #expect(tree.drop(try tree.point(in: b, .above, x: 0), carrying: folder, kind: .folder) == nil)
        // A tab or a pinned page does land there, so the guard is the folder and not the rows.
        let c = SidebarItem.tab(try tree.tabID("C"))
        #expect(tree.drop(try tree.point(in: b, .above, x: 0), carrying: c) != nil)
    }

    /// A whole group goes between groups, never inside one. Over another group's row its middle is a gap, not a place
    /// that takes it. The gap sits after the group it is over.
    @Test func aGroupOverAGroupRowLandsBetweenGroups() throws {
        let team = SidebarItem.tabGroup(try tree.groupID("Team"))
        let b = SidebarItem.tab(try tree.tabID("B"))
        let c = SidebarItem.tab(try tree.tabID("C"))
        let shown = tree.snapshot(carrying: team)
        let drop = try #require(shown.drop(at: try tree.point(in: team, .onto)))
        #expect(drop.place == .gap(above: b, below: c, depth: 0))
        #expect(drop.index == 4)
    }

    /// At every gap the fixture shows, the tab line and the drop are one answer. The line sits where the drop's index
    /// falls, at the drop's level. Every tab above it sorts before the index. Every tab below it sorts at or after.
    @Test func theTabLineAndTheDropAgreeAtEveryGap() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let page = SidebarItem.bookmark(UUID())
        for carried in [c, page] {
            let shown = tree.snapshot(carrying: carried)
            let gap = Tokens.Sidebar.rowGap
            for row in shown.rows where !shown.carried.contains(row.item) {
                for band in [RowBand.above, .below] {
                    let point = NSPoint(x: 0, y: band == .above ? row.frame.minY + row.frame.height * 0.1
                                                              : row.frame.maxY - row.frame.height * 0.1)
                    let drop = try #require(shown.drop(at: point), "\(row.item) \(band): no drop")
                    guard case .gap(_, _, let depth) = drop.place else {
                        Issue.record("\(row.item) \(band): a row's edge is a gap, not \(drop.place)")
                        continue
                    }
                    let line = try #require(shown.line(for: drop, rowGap: gap), "\(row.item) \(band): no line")
                    #expect(line.depth == depth)
                    for other in shown.rows where !shown.carried.contains(other.item) {
                        // A group row stands for its tabs, which run on below it. The tabs themselves are the rows
                        // either side of a gap.
                        guard case .tab = other.item else { continue }
                        let at = shown.rowTabs[try #require(shown.rows.firstIndex(of: other))].compactMap { id in
                            tree.tabs.firstIndex { $0.id == id }
                        }
                        guard let first = at.min(), let last = at.max() else { continue }
                        if other.frame.maxY < line.y {
                            #expect(last < drop.index, "\(row.item) \(band): \(other.item) above the line sorts after \(drop.index)")
                        } else if other.frame.minY > line.y {
                            #expect(first >= drop.index, "\(row.item) \(band): \(other.item) below the line sorts before \(drop.index)")
                        }
                    }
                }
            }
        }
    }

    /// Every tab gap reads beta 6's rule: the carried row's start, moved across since pick-up, against each level's
    /// step. This compares the snapshot with beta 6's own TabTree.dropParent call at every row edge and every
    /// sideways position, so the two cannot drift apart without a test saying so.
    @Test func everyGapSetsInAsBetaSixDid() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let shown = tree.snapshot(carrying: c)
        let groups = tree.groupOf
        func isSplit(_ item: SidebarItem?) -> Bool {
            guard let item, let at = shown.rows.firstIndex(where: { $0.item == item }) else { return false }
            return shown.rowTabs[at].count > 1
        }
        func betaParent(above: SidebarItem?, below: SidebarItem?, x: CGFloat) -> UUID? {
            if case .tabGroup? = above { return nil }
            let before: UUID? = if case .tab(let id)? = above { id } else { nil }
            let after: UUID? = if case .tab(let id)? = below { id } else { nil }
            let inGroup = before.flatMap { groups[$0] } != nil ? 1 : 0
            let nests = !isSplit(above) && !shown.carried.contains(where: { isSplit($0) })
            return TabTree.dropParent(before: before, after: after, in: shown.nodes, nests: nests) { level in
                SidebarListView.setsIn(x, depth: level + inGroup)
            }
        }
        for row in shown.rows where !shown.carried.contains(row.item) {
            for band in [RowBand.above, .below] {
                let y = band == .above ? row.frame.minY + row.frame.height * 0.1
                                       : row.frame.maxY - row.frame.height * 0.1
                for x in [CGFloat(0), 7, 14, 21, 28, 60, 200] {
                    let point = NSPoint(x: x, y: y)
                    let drop = try #require(shown.drop(at: point, grabbedAt: 0))
                    let above: SidebarItem? = if case .gap(let a, _, _) = drop.place { a } else { nil }
                    let below: SidebarItem? = if case .gap(_, let b, _) = drop.place { b } else { nil }
                    // A row's middle is its split offer, never a gap.
                    guard case .gap = drop.place else { continue }
                    let x0 = SidebarListView.nestX(pointer: x, grabbedAt: 0, depth: 0)
                    #expect(drop.folder == betaParent(above: above, below: below, x: x0),
                            "\(row.item) \(band) x=\(x): parent differs from beta 6")
                }
            }
        }
    }

    /// Below the last row inside an open tab, beta 6's sideways movement still sets the level: short of half a step
    /// the tab lands after that tab, at the next step in it goes under the ancestor it is set in under, and past the
    /// deepest step it becomes A1's last child. The line and the drop read the same answer.
    @Test func theLastChildOfAnOpenFolderPicksInsideOrAfterIt() throws {
        let c = SidebarItem.tab(try tree.tabID("C"))
        let b = SidebarItem.tab(try tree.tabID("B"))
        let a1ID = try tree.tabID("A1")
        let a1a = SidebarItem.tab(try tree.tabID("A1a"))
        let half = SidebarListView.folderIndent / 2
        let after = try #require(tree.drop(try tree.point(in: a1a, .below, x: SidebarListView.indent(depth: 1) - half - 1),
                                           carrying: c, grabbedAt: 0))
        #expect(after.place == .gap(above: a1a, below: b, depth: 0))
        #expect(after.folder == nil)
        let between = try #require(tree.drop(try tree.point(in: a1a, .below, x: SidebarListView.indent(depth: 2) - half - 1),
                                             carrying: c, grabbedAt: 0))
        #expect(between.place == .gap(above: a1a, below: b, depth: 1))
        let aID = try tree.tabID("A")
        #expect(between.folder == aID)
        let inside = try #require(tree.drop(try tree.point(in: a1a, .below, x: SidebarListView.indent(depth: 2) - half + 1),
                                            carrying: c, grabbedAt: 0))
        #expect(inside.place == .gap(above: a1a, below: b, depth: 2))
        #expect(inside.folder == a1ID)
        let shown = tree.snapshot(carrying: c)
        let line = try #require(shown.line(for: inside, rowGap: Tokens.Sidebar.rowGap))
        #expect(line.depth == 2)
    }

    /// A row with no tabs under it is the other boundary gap: short of half a step the tab lands after it, past it
    /// the tab becomes its first child.
    @Test func aRowWithNoChildrenPicksAFirstChildOrSibling() throws {
        var tree = TabDropFixture()
        tree.tab("A")
        let b = tree.tab("B")
        let c = tree.tab("C")
        let d = tree.tab("D")
        let carried = SidebarItem.tab(d)
        let half = SidebarListView.folderIndent / 2
        let after = try #require(tree.drop(try tree.point(in: .tab(b), .below, x: SidebarListView.indent(depth: 1) - half - 1),
                                           carrying: carried, grabbedAt: 0))
        #expect(after.place == .gap(above: .tab(b), below: .tab(c), depth: 0))
        #expect(after.folder == nil)
        let inside = try #require(tree.drop(try tree.point(in: .tab(b), .below, x: SidebarListView.indent(depth: 1) - half + 1),
                                            carrying: carried, grabbedAt: 0))
        #expect(inside.place == .gap(above: .tab(b), below: .tab(c), depth: 1))
        #expect(inside.folder == b)
        // At the end of the list the same row still offers its first child.
        let end = try #require(tree.drop(try tree.point(in: .tab(c), .below, x: SidebarListView.indent(depth: 1) + 1),
                                         carrying: carried, grabbedAt: 0))
        #expect(end.place == .gap(above: .tab(c), below: nil, depth: 1))
        #expect(end.folder == c)
    }

}
