#if canImport(UIKit)
import HappyCore
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

/// Home's list on UltraList (`SidebarList`) against the grouped
/// `SidebarView` it replaced: the same rows draw the same pixels, plain
/// rows and story rows alike, light and dark; and a finger and VoiceOver
/// do to a row what they did.
@MainActor
final class HostedSidebarListTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
    }

    /// Bots, tasks and a project as home lists them: a selected row, an
    /// unread one, a new one, every status, a fold, subtasks; then a
    /// heading over story rows with rings, status lines and an empty one.
    static func rows() -> [Row] {
        let now = Date().timeIntervalSince1970 * 1000
        var rows: [Row] = []
        var artifacts = Row(id: "direct:artifacts", nodeId: "direct:artifacts", kind: .space, label: "Artifacts", mark: .glyph("doc"), targetKind: "artifacts")
        artifacts.targetId = nil
        rows.append(artifacts)
        var calendar = Row(id: "surface:c", nodeId: "surface:c", kind: .space, label: "Family calendar", mark: .glyph("calendar"), targetKind: "surface")
        calendar.surfaceType = "calendar"
        rows.append(calendar)
        rows.append(Row(id: "direct:bots", nodeId: "direct:bots", kind: .separator, label: ""))
        rows.append(Row(id: "bot:happy", nodeId: "bot:happy", kind: .space, label: "Happy", mark: .happy, isHappy: true, agentId: "a-happy", targetKind: "bot"))
        rows.append(Row(id: "session:sub", nodeId: "session:sub", kind: .session, depth: 1, label: "A subtask that is working", status: .working, agentId: "a-sub"))
        rows.append(Row(id: "bot:ask", nodeId: "bot:ask", kind: .space, label: "Asks a question", mark: .placeholder(seed: "ask"), status: .awaitingInput, agentId: "a-ask", targetKind: "bot"))
        rows.append(Row(id: "bot:wait", nodeId: "bot:wait", kind: .space, label: "Waits", mark: .placeholder(seed: "wait"), status: .waiting, agentId: "a-wait", targetKind: "bot"))
        rows.append(Row(id: "bot:unread", nodeId: "bot:unread", kind: .space, label: "Has something unread for you, and a long name", mark: .placeholder(seed: "unread"), unread: true, agentId: "a-unread", targetKind: "bot"))
        var new = Row(id: "bot:new", nodeId: "bot:new", kind: .space, label: "Looped you in", mark: .glyph("agents"), agentId: "a-new", targetKind: "bot")
        new.isNew = true
        rows.append(new)
        rows.append(Row(id: "direct:projects", nodeId: "direct:projects", kind: .separator, label: ""))
        var project = Row(id: "project:p", nodeId: "project:p", kind: .space, label: "happy", mark: .placeholder(seed: "p"), targetKind: "project")
        project.collapsed = false
        rows.append(project)
        rows.append(Row(id: "session:p1", nodeId: "session:p1", kind: .session, depth: 1, label: "Session in the project", agentId: "a-p1"))
        rows.append(Row(id: "section:work", nodeId: "work", kind: .section, label: "Tasks", collapsed: false))
        func agent(_ id: String, _ label: String, _ mark: Row.Mark, _ status: Row.Status, _ line: String?, ago minutes: Double, unread: Bool = false) -> Row {
            var row = Row(id: "space:\(id)", nodeId: id, kind: .space, label: label, mark: mark, status: status, unread: unread, agentId: id)
            row.hasAgent = true
            row.statusLine = line
            row.statusTime = now - minutes * 60_000
            return row
        }
        let stories = [
            agent("charts", "Sales chart", .clay("deploy"), .none, "Your sales chart is live — tap a bar to see its month", ago: 4, unread: true),
            agent("ios", "iOS V2", .glyph("tasks"), .awaitingInput, "Ready for a new test build with the story rings, the round videos and the repost chip. Send it to TestFlight?", ago: 12),
            agent("deploy", "Deploy", .clay("navigation"), .none, "Shipped", ago: 60 * 26),
            agent("quiet", "New task", .glyph("tasks"), .none, nil, ago: 0),
        ]
        rows += Rows.withStories(stories, rings: [
            "charts": StoryRing(agentId: "charts", storyIds: ["s1"], unseenCount: 1, latestPostedAt: nil),
            "deploy": StoryRing(agentId: "deploy", storyIds: ["s5"], unseenCount: 0, latestPostedAt: nil),
        ])
        return rows
    }

    private func host(_ style: UIUserInterfaceStyle) async throws -> (UIWindow, UIViewController) {
        let scene = try await hostedActiveScene()
        let root = UIViewController()
        root.view.backgroundColor = UIColor(Palette.groupedGround)
        let window = hostedKeyWindow(in: scene, root: root)
        window.overrideUserInterfaceStyle = style
        addTeardownBlock { @MainActor in window.isHidden = true }
        return (window, root)
    }

    private func list(in root: UIViewController, rows: [Row], frame: CGRect) async -> SidebarList {
        let list = SidebarList(frame: frame)
        root.view.addSubview(list)
        list.layoutIfNeeded()
        list.apply(rows)
        await list.settle()
        return list
    }

    private func image(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
    }

    /// The share of pixels that differ by more than a little, and where.
    private func difference(_ a: UIImage, _ b: UIImage) -> (share: Double, box: CGRect) {
        guard let a = a.cgImage, let b = b.cgImage, a.width == b.width, a.height == b.height else { return (1, .null) }
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let left = pixels(a), right = pixels(b)
        var differing = 0
        var box = CGRect.null
        for index in stride(from: 0, to: left.count, by: 4) {
            let d = max(abs(Int(left[index]) - Int(right[index])), abs(Int(left[index + 1]) - Int(right[index + 1])), abs(Int(left[index + 2]) - Int(right[index + 2])))
            guard d > 24 else { continue }
            differing += 1
            let pixel = index / 4
            box = box.union(CGRect(x: pixel % a.width, y: pixel / a.width, width: 1, height: 1))
        }
        return (Double(differing) / Double(a.width * a.height), box)
    }

    /// The same rows, grouped, side by side: the list on UltraList draws what
    /// `SidebarView` drew, to the pixel but for the working signal's frame.
    func testTheListDrawsWhatTheSidebarDrew() async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let (window, root) = try await host(style)
            let frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: 1500)
            let rows = Self.rows()
            let old = SidebarView(frame: frame)
            old.style = .grouped
            old.selectedRowId = "bot:wait"
            root.view.addSubview(old)
            old.apply(rows)
            old.layoutIfNeeded()
            let new = await list(in: root, rows: rows, frame: frame)
            new.selectedRowId = "bot:wait"
            await new.settle()
            // The pictures and placeholders land, and the new row's pulse ends.
            try await Task.sleep(for: .milliseconds(Int((Metrics.newPulseDuration + 0.5) * 1000)))
            old.isHidden = true
            let after = image(root.view)
            old.isHidden = false
            new.isHidden = true
            let before = image(root.view)
            new.isHidden = false
            let name = style == .dark ? "dark" : "light"
            if let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"] {
                try? before.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("parity-sidebarview-\(name).png"))
                try? after.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("parity-sidebarlist-\(name).png"))
            }
            let (share, box) = difference(before, after)
            print("PARITY \(name): \(share * 100)% of pixels differ, in \(box)")
            XCTAssertLessThan(share, 0.002, "\(name): the list draws differently from the sidebar, in \(box)")
            XCTAssertEqual(old.layoutResult?.frames.count, rows.count)
            window.isHidden = true
        }
    }

    /// A press lights a row that opens and tells home it may open next; a
    /// tap opens it; a tap on a story ring opens the stories instead; a
    /// heading opens nothing.
    func testPressTapAndRing() async throws {
        let (window, root) = try await host(.light)
        let list = await list(in: root, rows: Self.rows(), frame: window.bounds)
        var opened: [String] = []
        var intents: [String] = []
        var stories: [String] = []
        list.onSelect = { opened.append($0.id) }
        list.onIntent = { intents.append($0.id) }
        list.onOpenStory = { row, _ in stories.append(row.id) }
        let bot = try XCTUnwrap(list.view(for: "bot:ask"))
        XCTAssertTrue(list.lightsOnPress(bot.row))
        bot.pressed = true
        XCTAssertEqual(bot.fillColor?.resolvedColor(with: bot.traitCollection), UIColor(Palette.groupedCellHighlight).resolvedColor(with: bot.traitCollection))
        bot.pressed = false
        XCTAssertEqual(bot.fillColor?.resolvedColor(with: bot.traitCollection), UIColor(Palette.groupedCard).resolvedColor(with: bot.traitCollection))
        list.pressed(bot)
        XCTAssertEqual(intents, ["bot:ask"])
        list.tap(bot, at: CGPoint(x: bot.box.midX, y: bot.box.midY))
        XCTAssertEqual(opened, ["bot:ask"])

        let story = try XCTUnwrap(list.view(for: "space:charts"))
        let ring = try XCTUnwrap(story.frames.ring)
        list.tap(story, at: CGPoint(x: ring.midX, y: ring.midY))
        XCTAssertEqual(stories, ["space:charts"], "the ring opens the stories")
        list.tap(story, at: CGPoint(x: story.box.maxX - 40, y: story.box.midY))
        XCTAssertEqual(opened, ["bot:ask", "space:charts"], "the rest of the row opens the conversation")

        let heading = try XCTUnwrap(list.view(for: "section:work"))
        XCTAssertFalse(list.lightsOnPress(heading.row))
        list.tap(heading, at: CGPoint(x: heading.box.midX, y: heading.box.midY))
        XCTAssertEqual(opened.count, 2, "a heading opens nothing")

        // Only the row's box takes a touch: not the gap above it.
        let first = try XCTUnwrap(list.view(for: "bot:happy"))
        XCTAssertGreaterThan(first.box.minY, 0, "the gap between the cards is the slot's")
        XCTAssertFalse(first.point(inside: CGPoint(x: first.box.midX, y: first.box.minY - 4), with: nil))
        XCTAssertTrue(first.point(inside: CGPoint(x: first.box.midX, y: first.box.midY), with: nil))
    }

    /// A hold shows the row's menu over the blurred screen; VoiceOver has
    /// the same menu, and the stories, as the row's actions, and reads each
    /// row as what it is.
    func testHoldAndVoiceOver() async throws {
        let (window, root) = try await host(.light)
        let list = await list(in: root, rows: Self.rows(), frame: window.bounds)
        var ran: [String] = []
        list.onSelect = { _ in }
        list.onOpenStory = { _, _ in }
        list.menu = { row in [[MenuItem(title: "Archive", icon: "archive") { ran.append(row.id) }]] }
        let story = try XCTUnwrap(list.view(for: "space:charts"))
        let actions = try XCTUnwrap(story.accessibilityCustomActions)
        XCTAssertEqual(actions.map(\.name), [Strings.Stories.watchStory, "Archive"])
        _ = actions[1].actionHandler?(actions[1])
        XCTAssertEqual(ran, ["space:charts"])

        XCTAssertEqual(story.accessibilityLabel, "Sales chart")
        XCTAssertTrue(story.accessibilityTraits.contains(.button))
        XCTAssertEqual(list.view(for: "section:work")?.accessibilityTraits, .header)
        XCTAssertEqual(story.accessibilityFrame.height, story.box.height, accuracy: 0.5, "VoiceOver frames the row, not its slot")

        let bot = try XCTUnwrap(list.view(for: "bot:ask"))
        list.openHold(bot)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(root.view.subviews.first { $0 is HoldOverlay }, "the hold is shown")
        for case let overlay as HoldOverlay in root.view.subviews { overlay.close(animated: false) }
        XCTAssertEqual(window.isKeyWindow, true)
    }

    /// A change touches only the rows it changed: the rest keep their
    /// drawings, and a row that went is gone.
    func testAChangeRedrawsOnlyWhatChanged() async throws {
        let (window, root) = try await host(.light)
        var rows = Self.rows()
        let list = await list(in: root, rows: rows, frame: window.bounds)
        let before = Dictionary(uniqueKeysWithValues: list.list.items.map { ($0.identity, $0.revision) })
        let renamed = try XCTUnwrap(rows.firstIndex { $0.id == "bot:wait" })
        rows[renamed].label = "Waits, renamed"
        rows.removeAll { $0.id == "bot:new" }
        list.apply(rows)
        await list.settle()
        let after = Dictionary(uniqueKeysWithValues: list.list.items.map { ($0.identity, $0.revision) })
        XCTAssertNil(after["bot:new"])
        XCTAssertNotEqual(after["bot:wait"], before["bot:wait"], "the renamed row draws again")
        for (id, revision) in after where id != "bot:wait" && id != "bot:unread" && id != "section:work" {
            // The row over the one that went now ends its card, and the
            // heading after it now starts nearer: they draw again too.
            XCTAssertEqual(revision, before[id], "\(id) drew again for nothing")
        }
    }
}
#endif
