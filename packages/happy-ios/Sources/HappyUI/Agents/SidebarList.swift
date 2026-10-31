#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit
import UltraView

/// Home's list on UltraList: the grouped sidebar's rows (`SidebarLayout`'s
/// inset cards), only those near the screen mounted, each one's text drawn
/// off the main thread. Where `SidebarView` keeps a view per row and lays
/// every row out again on each frame it moves, this keeps a window of rows
/// and lays nothing out on the main thread: the rows' frames, slots and
/// drawings are worked out by `ApplyPipeline` off it, and a change applies
/// only the rows it touched.
///
/// What a row looks like and what a finger does to it are `SidebarView`'s:
/// the same frames, cards, hairlines, faces and marks; a press lights the
/// row, a tap opens it, a hold shows its conversation over the blurred
/// screen with its menu, a tap on a story ring opens its stories. The rows
/// on screen stay where they are when rows change above them, and at the
/// very top new rows are seen arriving.
///
/// UltraList is not a scroll view, so the screen's bar shades `edge`
/// instead: a scroll view that never scrolls under a finger and follows the
/// list's place, which iOS 26's soft scroll edge and the scroll indicator
/// read. The list rides inside it, held still on screen as its place
/// changes, so the soft edge shades the rows as it would its own content.
@MainActor
final class SidebarList: UIView {
    let list = UltraListView(engineMode: .keyframe)
    /// The scroll view the bar's edge and the scroll indicator follow.
    let edge = SidebarListEdge()

    var onSelect: ((Row) -> Void)?
    /// A story row's ring was tapped: its agent's stories, not its conversation.
    var onOpenStory: ((Row, UIView) -> Void)?
    /// A finger came down on a row that opens: it may be opened next.
    var onIntent: ((Row) -> Void)?
    /// What a hold on the row offers, in groups; nil for a row that has nothing.
    var menu: ((Row) -> [[MenuItem]]?)?
    /// What a hold shows of the row over its menu: its conversation, read
    /// only, or nothing for a row that has none.
    var preview: ((Row) -> UIViewController?)?
    /// The preview was tapped: the row opens at once, under it.
    var onOpenPreview: ((Row) -> Void)?
    var images: Images?

    /// The list moved: a finger, a glide or a jump.
    var onScroll: (() -> Void)?
    var onWillBeginDragging: (() -> Void)?
    /// The finger lifted; true when the list glides on.
    var onDidEndDragging: ((Bool) -> Void)?
    /// A glide came to rest.
    var onDidEndDecelerating: (() -> Void)?
    /// The finger lifts and the list would glide to `offset` (as a scroll
    /// view's `contentOffset.y`): the screen may send it somewhere else.
    var onWillEndDragging: ((_ velocity: CGFloat, _ offset: inout CGFloat) -> Void)?

    /// The row drawn selected: on home, the one whose screen is coming in.
    var selectedRowId: String? {
        didSet {
            guard selectedRowId != oldValue else { return }
            for view in mountedViews { view.selected = view.row.id == selectedRowId }
            update()
        }
    }

    private(set) var rows: [Row] = []
    /// The room above the rows and below them, and the indicator's.
    private(set) var contentInsets = UIEdgeInsets.zero
    private var prepared: Prepared?
    private var items: [String: SidebarItem] = [:]
    private var requested: Input?
    private var observation: ApplyObservation?
    private var hold: HoldOverlay?
    /// Moves the story rows' times on, once a minute while on screen.
    private var clock: Timer?
    private var indicatorFlashed: CFTimeInterval = 0
    /// Applies waiting for their rows to be drawn.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    struct Input: Equatable, Sendable {
        var rows: [Row]
        var width: CGFloat
        var dark: Bool
        var displayScale: CGFloat
        var textScale: CGFloat
        var selected: String?
        var minute: Int
    }

    /// One slot of the list, as worked out off the main thread.
    struct Entry: Sendable {
        var row: Row
        var size: CGSize
        /// The row's box, from the slot's top-left.
        var box: CGRect
        /// Where the slot starts in the content.
        var top: CGFloat
        var drawing: SidebarItemDrawing
        var revision: UInt64
    }

    struct Prepared: Sendable {
        var input: Input
        var entries: [Entry]
        var contentHeight: CGFloat
        var sequence: UInt64
    }

    private lazy var pipeline = ApplyPipeline<Input?, Prepared?, Prepared>(
        input: nil,
        state: nil,
        derive: { input, previous in
            guard let input, input != previous?.input else { return nil }
            let result = Self.derive(input, previous: previous)
            return (result, result)
        },
        apply: { [weak self] result in
            guard let self, let requested, result.input == requested else { return false }
            show(result)
            return true
        }
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        list.accessibilityIdentifier = "home-list"
        list.onScroll = { [weak self] _ in self?.scrolled() }
        list.onVisibleWindowChanged = { [weak self] in self?.mirror() }
        list.willBeginDragging = { [weak self] in
            self?.flashIndicator(force: true)
            self?.onWillBeginDragging?()
        }
        list.didEndDragging = { [weak self] in
            guard let self else { return }
            onDidEndDragging?(list.isDecelerating)
        }
        list.didEndScrolling = { [weak self] in self?.onDidEndDecelerating?() }
        list.shouldStopScrolling = { [weak self] velocity in self?.release(velocity: velocity) ?? false }
        addSubview(edge)
        edge.addSubview(list)
        observation = pipeline.observation
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.update() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if edge.frame != bounds {
            edge.frame = bounds
            list.frame = CGRect(origin: edge.bounds.origin, size: bounds.size)
        }
        update()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        clock?.invalidate()
        clock = nil
        if newWindow != nil {
            // On the minute, so every time turns together.
            let next = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60
            let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else {
            // Leaving the screen mid-hold: nothing is left behind in the window.
            hold?.close(animated: false)
        }
    }

    // MARK: Rows

    /// Shows `rows`. They are laid out and drawn off the main thread; the
    /// list takes them in one apply, touching only the rows that changed.
    func apply(_ rows: [Row]) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.rows = rows
        update()
    }

    /// Until the rows last given are on the list, measured and drawn
    /// (a second at most).
    func settle() async {
        if requested != prepared?.input { await withCheckedContinuation { waiters.append($0) } }
        let deadline = CACurrentMediaTime() + 1
        while CACurrentMediaTime() < deadline {
            let ids = prepared?.entries.map(\.row.id) ?? []
            let shown = list.items.map(\.identity) == ids
            if shown, ids.isEmpty || list.loadedItemViews.allSatisfy(\.isDisplayReady) { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func update() {
        guard bounds.width > 0 else { return }
        let traits = traitCollection
        let input = Input(
            rows: rows, width: bounds.width, dark: traits.userInterfaceStyle == .dark,
            displayScale: traits.displayScale > 0 ? traits.displayScale : 3,
            textScale: StoryRowText.scale(traits), selected: selectedRowId,
            // Only story rows read the clock.
            minute: rows.contains { $0.story != nil } ? Int(Date().timeIntervalSince1970 / 60) : 0
        )
        guard input != requested else { return }
        requested = input
        pipeline.update { $0 = input }
    }

    /// The rows laid out as grouped cards at `input`'s width, each slot's
    /// drawing, and a new revision only for a slot that draws differently.
    nonisolated static func derive(_ input: Input, previous: Prepared?) -> Prepared {
        typealias G = GroupedSidebarMetrics
        let layoutRows = SidebarView.layoutRows(input.rows, textScale: input.textScale)
        let result = SidebarLayout.layout(layoutRows, width: input.width, top: G.contentTop, bottom: G.contentBottom, scale: input.displayScale, style: .grouped)
        let slots = SidebarLayout.slots(layoutRows, result, width: input.width)
        var old: [String: Entry] = [:]
        for entry in previous?.entries ?? [] { old[entry.row.id] = entry }
        var sequence = previous?.sequence ?? 0
        let now = Date(timeIntervalSince1970: TimeInterval(input.minute * 60))
        let entries = slots.map { slot -> Entry in
            let row = input.rows[slot.row]
            let drawing = SidebarItemDrawing(
                row: row, frame: SidebarLayout.local(result.frames[slot.row], top: slot.frame.minY),
                selected: row.id == input.selected, dark: input.dark, displayScale: input.displayScale,
                textScale: input.textScale, now: row.story == nil ? .distantPast : now
            )
            var entry = Entry(row: row, size: slot.frame.size, box: slot.box, top: slot.frame.minY, drawing: drawing, revision: 0)
            if let kept = old[row.id], kept.drawing == drawing, kept.size == entry.size {
                entry.revision = kept.revision
            } else {
                sequence += 1
                entry.revision = sequence
            }
            return entry
        }
        return Prepared(input: input, entries: entries, contentHeight: result.contentHeight, sequence: sequence)
    }

    private func show(_ next: Prepared) {
        let previousIDs = prepared?.entries.map(\.row.id)
        let target = anchor(next)
        prepared = next
        var shown: [SidebarItem] = []
        var kept: [String: SidebarItem] = [:]
        var touched = 0
        for entry in next.entries {
            let item: SidebarItem
            if let existing = items[entry.row.id], existing.revision == entry.revision {
                item = existing
            } else {
                item = SidebarItem(entry: entry, owner: self)
                touched += 1
            }
            shown.append(item)
            kept[entry.row.id] = item
        }
        items = kept
        let structural = previousIDs != nil && previousIDs != next.entries.map(\.row.id)
        let animated = structural && window != nil && !UIAccessibility.isReduceMotionEnabled
        ApplyPerf.measure(.homeList) {
            list.applyChanges(items: shown, newSize: bounds.size, scrollTo: target, anchorMode: .automatic, compensatesInsetChange: false, transition: animated ? .easeInOut(0.25) : .none)
            return touched
        }
        edge.contentSize = CGSize(width: bounds.width, height: next.contentHeight)
        mirror()
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// The reader's place, kept: rows that changed above what is on screen
    /// would otherwise push everything under the eye (a conversation added
    /// or archived elsewhere, Prioritizing's reordering). The unchanged row
    /// `SidebarScrollAnchor` picks stays where it is; at its top the list
    /// stays at its top, so arrivals show.
    private func anchor(_ next: Prepared) -> ListScrollTarget? {
        guard let previous = prepared?.entries, !previous.isEmpty, bounds.height > 0, !isAtTop else { return nil }
        let ids = previous.map(\.row.id)
        let nextIDs = next.entries.map(\.row.id)
        guard ids != nextIDs else { return nil }
        let offset = contentOffsetY
        let viewport = CGRect(x: 0, y: offset + contentInsets.top, width: bounds.width, height: bounds.height - contentInsets.top - contentInsets.bottom)
        let boxes = previous.map { $0.box.offsetBy(dx: 0, dy: $0.top) }
        let nextBoxes = next.entries.map { $0.box.offsetBy(dx: 0, dy: $0.top) }
        guard let index = SidebarScrollAnchor.index(previous: ids, next: nextIDs, boxes: boxes, nextBoxes: nextBoxes, viewport: viewport),
              let nextIndex = nextIDs.firstIndex(of: ids[index]) else { return nil }
        let moved = nextBoxes[nextIndex].minY - boxes[index].minY
        let top = -contentInsets.top
        let bottom = max(top, next.contentHeight + contentInsets.bottom - bounds.height)
        let place = min(bottom, max(top, offset + moved))
        // The anchor's slot top lands this far past the inset's edge.
        return ListScrollTarget(index: nextIndex, identity: nextIDs[nextIndex], pointOffset: next.entries[nextIndex].top - place - contentInsets.top)
    }

    // MARK: Place

    /// Where the rows start and end, under the bar and above the toolbar,
    /// and the indicator's run. `keepsTop`: the list rests at its top and
    /// stays there; otherwise what is on screen stays where it is.
    func setInsets(_ insets: UIEdgeInsets, indicator: UIEdgeInsets, keepsTop: Bool) {
        edge.verticalScrollIndicatorInsets = indicator
        guard insets != contentInsets else { return }
        contentInsets = insets
        edge.contentInset = insets
        list.applyChanges(newSize: bounds.width > 0 ? bounds.size : nil, newInsets: .init(top: insets.top, bottom: insets.bottom), anchorMode: keepsTop ? .automatic : .preserveVisibleContent, compensatesInsetChange: keepsTop, transition: .none)
        mirror()
    }

    /// The list's place as a scroll view's `contentOffset.y`: `-top` at rest
    /// at its top, less past it under a pull, more as it is read down.
    var contentOffsetY: CGFloat {
        guard let entries = prepared?.entries else { return -contentInsets.top }
        for index in list.loadedIndexRange where entries.indices.contains(index) {
            guard let frame = list.settledFrame(at: index) else { continue }
            return entries[index].top - frame.minY
        }
        return -contentInsets.top
    }

    var isAtTop: Bool { contentOffsetY <= -contentInsets.top + 1 }
    var isDragging: Bool { list.isDragging }
    var isDecelerating: Bool { list.isDecelerating }
    var isTracking: Bool { list.isTracking }

    /// Straight to the top, or gliding there.
    func scrollToTop(animated: Bool) {
        list.scrollToTop(animated: animated)
    }

    /// Moves the list to `offset` (a scroll view's `contentOffset.y`), at
    /// once or gliding there.
    func setContentOffsetY(_ offset: CGFloat, animated: Bool = false) {
        guard let entries = prepared?.entries, !entries.isEmpty else { return }
        // Row `index`'s top lands `offset` past the inset's edge: its content
        // place, less where the screen starts in the content.
        let index = entries.lastIndex { $0.top <= max(0, offset + contentInsets.top) } ?? 0
        let distance = entries[index].top - offset - contentInsets.top
        list.scrollTo(ListScrollTarget(index: index, identity: entries[index].row.id, pointOffset: distance), transition: animated ? .uiKitScroll() : .immediate)
        mirror()
    }

    private func scrolled() {
        if list.isDecelerating, !list.isTracking { glidedAt = CACurrentMediaTime() }
        mirror()
        flashIndicator(force: false)
        onScroll?()
    }

    /// The edge follows the list, so the bar's shade and the indicator read
    /// its place.
    private func mirror() {
        let offset = contentOffsetY
        guard abs(edge.contentOffset.y - offset) > 0.01 else { return }
        edge.contentOffset.y = offset
        // The list stays where it is on screen.
        list.frame.origin = edge.bounds.origin
    }

    /// While the list moves under a finger or glides, the indicator shows.
    private func flashIndicator(force: Bool) {
        guard force || list.isTracking || list.isDecelerating || list.isDragging else { return }
        let now = CACurrentMediaTime()
        guard force || now - indicatorFlashed > 0.4 else { return }
        indicatorFlashed = now
        edge.flashScrollIndicators()
    }

    /// The finger let go at `velocity` (content points a second): a scroll
    /// view would glide to where its deceleration stops it. When the screen
    /// sends it elsewhere, the list stops and goes there instead.
    private func release(velocity: Double) -> Bool {
        guard let onWillEndDragging else { return false }
        let current = contentOffsetY
        // The finger's velocity (points a second, down positive) as the
        // content's, points a millisecond, up positive; UIScrollView's
        // normal deceleration, 0.998 a millisecond.
        let speed = CGFloat(-velocity) / 1000
        var target = current + speed * 0.998 / (1 - 0.998)
        onWillEndDragging(speed, &target)
        // Where the list would come to rest by itself, inside its edges as
        // they are now (the stories may have just changed the top).
        let top = -contentInsets.top
        let bottom = max(top, (prepared?.contentHeight ?? 0) + contentInsets.bottom - bounds.height)
        let resting = min(bottom, max(top, current + speed * 0.998 / (1 - 0.998)))
        guard abs(min(bottom, max(top, target)) - resting) > 1 else { return false }
        let goal = min(bottom, max(top, target))
        DispatchQueue.main.async { [weak self] in self?.glide(to: goal) }
        return true
    }

    /// The list glides on with no finger on it: a touch now only stops it.
    var isGliding: Bool {
        list.isDecelerating && !list.isTracking || CACurrentMediaTime() - glidedAt < 0.05
    }
    private var glidedAt: CFTimeInterval = 0

    private func glide(to offset: CGFloat) {
        setContentOffsetY(offset, animated: true)
    }

    // MARK: Reading

    /// The rows on the list now, near the screen.
    var mountedViews: [SidebarItemView] { list.loadedItemViews.compactMap { $0 as? SidebarItemView } }

    func view(for rowId: String) -> SidebarItemView? { mountedViews.first { $0.row.id == rowId } }

    /// The rows shown, in the order drawn.
    var shownRows: [Row] { rows }

    /// The places among `shownRows` on screen now; nil before they are drawn.
    var visibleRange: ClosedRange<Int>? {
        let on = visibleEntries.compactMap { entry in rows.firstIndex { $0.id == entry.row.id } }
        guard let first = on.min(), let last = on.max() else { return nil }
        return first...last
    }

    /// The rows on screen now, top first.
    var visibleRows: [Row] { visibleEntries.map(\.row) }

    private var visibleEntries: [Entry] {
        guard let entries = prepared?.entries else { return [] }
        let window = bounds.inset(by: UIEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0))
        return list.loadedIndexRange.compactMap { index in
            guard entries.indices.contains(index), let frame = list.settledFrame(at: index) else { return nil }
            let box = entries[index].box.offsetBy(dx: frame.minX, dy: frame.minY)
            return box.intersects(window) ? entries[index] : nil
        }
    }

    // MARK: Touch

    /// A press began on `view`'s row.
    func pressed(_ view: SidebarItemView) {
        guard onSelect != nil, hold == nil else { return }
        onIntent?(view.row)
    }

    /// Whether a press lights `row`: it opens something.
    func lightsOnPress(_ row: Row) -> Bool {
        guard hold == nil else { return false }
        return row.kind == .section ? false : onSelect != nil
    }

    /// A tap on `view` at `point`, in the view.
    func tap(_ view: SidebarItemView, at point: CGPoint) {
        // The touch that opened a hold, let go: the hold stays and that is all.
        guard hold == nil else { return }
        let row = view.row
        switch row.kind {
        case .section, .separator:
            // Home folds nothing.
            break
        default:
            // A ring with stories in it opens them, with a finger's room around it.
            if let ring = view.frames.ring, (row.story?.segments ?? 0) > 0, let onOpenStory,
               ring.insetBy(dx: -8, dy: -8).contains(point), let ringView = view.ringView {
                onOpenStory(row, ringView)
                return
            }
            onSelect?(row)
        }
    }

    /// Telegram's hold: the screen blurs, the row's conversation grows out
    /// of it with the menu under it, and a light tap is felt. A row with
    /// neither a menu nor a conversation shows nothing.
    func openHold(_ view: SidebarItemView) {
        guard hold == nil, let window else { return }
        let row = view.row
        let items = menu?(row) ?? []
        let preview = preview?(row)
        guard !items.isEmpty || preview != nil else { return }
        Haptics.play(.hold)
        let source = view.convert(view.box, to: window)
        // The row as it rests, not pressed.
        view.pressed = false
        let snapshot = preview == nil ? view.resizableSnapshotView(from: view.box, afterScreenUpdates: true, withCapInsets: .zero) : nil
        let overlay = HoldOverlay(window: window, items: items, preview: preview, source: source, snapshot: snapshot)
        overlay.onOpen = { [weak self] in self?.onOpenPreview?(row) }
        overlay.onLeave = { [weak self, weak overlay] in
            if self?.hold === overlay { self?.hold = nil }
        }
        hold = overlay
        // Under the blur the list holds still.
        for pan in list.contentView.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer {
            pan.isEnabled = false
            pan.isEnabled = true
        }
        list.haltScrolling()
        overlay.present()
    }

    /// What VoiceOver offers on `row`: its stories, then its hold's menu.
    func actions(for view: SidebarItemView) -> [UIAccessibilityCustomAction] {
        let row = view.row
        var actions: [UIAccessibilityCustomAction] = []
        if (row.story?.segments ?? 0) > 0, let onOpenStory {
            actions.append(UIAccessibilityCustomAction(name: Strings.Stories.watchStory) { [weak view] _ in
                guard let ring = view?.ringView else { return false }
                onOpenStory(row, ring)
                return true
            })
        }
        return actions + (menu?(row) ?? []).joined().map { item in
            UIAccessibilityCustomAction(name: item.title, image: Glyphs.image(item.icon)) { _ in
                item.run()
                return true
            }
        }
    }
}

extension SidebarList: StoriesList {
    var offsetY: CGFloat { contentOffsetY }
    var insetTop: CGFloat { contentInsets.top }
}

/// The scroll view home's bar shades: it holds the list, never scrolls
/// under a finger, and follows the list's place and size.
final class SidebarListEdge: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // The list inside takes the touches; this only follows it.
        isScrollEnabled = false
        panGestureRecognizer.isEnabled = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        showsHorizontalScrollIndicator = false
        // The list answers the status bar.
        scrollsToTop = false
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// One row of home's list: its slot's size and drawing, and the row it shows.
@MainActor
final class SidebarItem: ListRow {
    let identity: String
    let revision: UInt64
    let entry: SidebarList.Entry
    let node: NodeRow
    weak var owner: SidebarList?
    var measuresAsynchronously: Bool { true }

    init(entry: SidebarList.Entry, owner: SidebarList) {
        identity = entry.row.id
        revision = entry.revision
        self.entry = entry
        self.owner = owner
        let drawing = entry.drawing
        let height = entry.size.height
        node = NodeRow(identity: entry.row.id, revision: entry.revision) {
            var style = Style()
            style.height = .points(height)
            let root = UltraNode(style: style)
            root.drawing = drawing
            return root
        }
    }

    func prepare(width: Double, environment: RenderEnvironment) async -> ListPreparation? { await node.prepare(width: width, environment: environment) }
    func makeView() -> ListRowView { SidebarItemView(item: self) }
    func apply(to view: ListRowView, transition: ListTransition) { (view as? SidebarItemView)?.apply(self, transition: transition) }
}
#endif
