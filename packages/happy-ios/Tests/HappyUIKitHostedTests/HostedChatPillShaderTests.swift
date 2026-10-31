#if canImport(UIKit)
import Foundation
import HappyCore
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

private struct PillUnreachable: AgentTransport {
    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
        throw URLError(.cannotConnectToHost)
    }
    func stream(path: String, credential: String, headers: [String: String]) async throws -> HTTP1Stream {
        throw URLError(.cannotConnectToHost)
    }
    func reset() async {}
    func close() async {}
}

/// The chat's header wears the chat's own shader, tinted
/// (`ChatPillShader.chosen`), under the title's capsule and the bar's Back
/// and Compose: from the header's first frame, still unless Animated Avatars
/// is on, and drawn only while the chat shows and the app is in front.
@MainActor
final class HostedChatPillShaderTests: XCTestCase {
    private static let agentId = "pill-shader-agent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LiveAvatars.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LiveAvatars.key)
        super.tearDown()
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    /// A chat with an agent on an unreachable computer, and the navigation
    /// it will be pushed onto, in a key window.
    private func chat() async throws -> (UIWindow, UINavigationController, ChatViewController) {
        let account = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "pill-test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil, agentTransport: { _ in PillUnreachable() }
        )
        await account.agentConnections.setForeground(false)
        let paired = try await account.agentConnections.add(JSONDecoder().decode(AgentConnectionCredentials.self,
            from: Data(#"{"address":"pill-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"test"}"#.utf8)), name: "Pill test")
        addTeardownBlock { @MainActor in
            Session.forget(paired.id)
            try await account.agentConnections.remove(paired.id)
        }
        let context = AppContext(account: account, variant: .preview, version: "test")
        let session = try XCTUnwrap(Session.session(for: paired.id, context: context))
        let chat = ChatViewController(session: session, agentId: Self.agentId, title: "Pill shader", spaceId: nil, intro: nil)
        let navigation = UINavigationController(rootViewController: UIViewController())
        AppCoordinator.applyAppearance(to: navigation.navigationBar)
        let scene = try await hostedActiveScene()
        let original = scene.keyWindow
        let window = hostedKeyWindow(in: scene, root: navigation)
        addTeardownBlock { @MainActor in
            window.isHidden = true
            original?.makeKey()
        }
        window.layoutIfNeeded()
        return (window, navigation, chat)
    }

    private static func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Pushed, the header's first layout draws the capsule's shader in that
    /// same frame, under the glass, and the bar's circles get theirs.
    func testTheHeaderWearsTheChatsShaderFromItsFirstFrame() async throws {
        let renderer = try XCTUnwrap(AvatarShaderRenderer.shared, "no Metal")
        _ = await renderer.ready()
        let (window, navigation, chat) = try await chat()
        navigation.pushViewController(chat, animated: false)
        window.layoutIfNeeded()

        let header = try XCTUnwrap(chat.navigationItem.titleView as? ChatHeaderView)
        let shader = header.backdrop.shader
        XCTAssertTrue(shader.drawn, "the capsule's shader waited for a later frame")
        XCTAssertFalse(shader.isHidden)
        XCTAssertEqual(shader.index, AvatarPlaceholder.index(seed: Self.agentId))
        XCTAssertEqual(shader.drawing.look, ChatPillShader.chosen.look(dark: false))
        // Under the glass, in its frame: the glass blurs it.
        let capsule = header.capsule
        XCTAssertTrue(header.backdrop.superview === capsule.superview)
        let order = header.subviews
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: header.backdrop)), try XCTUnwrap(order.firstIndex(of: capsule)))
        XCTAssertEqual(header.backdrop.frame, capsule.frame)
        // One canvas: the bar.
        let bar = navigation.navigationBar
        XCTAssertEqual(shader.drawing.canvas?.size, bar.bounds.size)

        // Back and Compose: one under each of the bar's circles, under the bar.
        try await until { navigation.transitionCoordinator == nil }
        let backdrops = Self.views(GlassShaderBackdrop.self, in: navigation.view).filter { $0.accessibilityIdentifier == "chat-bar-shader" }
        XCTAssertEqual(backdrops.count, 2)
        let circles = ChatBarShaders.circles(in: bar, excluding: backdrops).map { bar.convert($0, to: navigation.view) }
        for backdrop in backdrops {
            XCTAssertFalse(backdrop.isHidden)
            XCTAssertEqual(backdrop.alpha, 1)
            XCTAssertTrue(backdrop.superview === bar.superview)
            XCTAssertTrue(circles.contains(backdrop.frame), "\(backdrop.frame) is under none of \(circles)")
            try await until { backdrop.shader.drawn && !backdrop.shader.isHidden }
        }
        let hosts = try XCTUnwrap(bar.superview).subviews
        for backdrop in backdrops {
            XCTAssertLessThan(try XCTUnwrap(hosts.firstIndex(of: backdrop)), try XCTUnwrap(hosts.firstIndex(of: bar)))
        }

        // Back: they go with the chat.
        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        XCTAssertTrue(Self.views(GlassShaderBackdrop.self, in: navigation.view).isEmpty)
    }

    /// It holds the still frame unless Animated Avatars is on; on, it moves,
    /// but not in the background or under another screen.
    func testItMovesOnlyWhenAskedAndShown() async throws {
        let renderer = try XCTUnwrap(AvatarShaderRenderer.shared, "no Metal")
        let (window, navigation, chat) = try await chat()
        navigation.pushViewController(chat, animated: false)
        window.layoutIfNeeded()
        let header = try XCTUnwrap(chat.navigationItem.titleView as? ChatHeaderView)
        try await until { header.backdrop.shader.drawn }
        try await Task.sleep(for: .milliseconds(300))

        func frames(over milliseconds: Int) async throws -> Int {
            let before = renderer.presented
            try await Task.sleep(for: .milliseconds(milliseconds))
            return renderer.presented - before
        }
        let still = try await frames(over: 400)
        XCTAssertEqual(still, 0, "it moves with Animated Avatars off")

        LiveAvatars.isEnabled = true
        try await Task.sleep(for: .milliseconds(100))
        let moving = try await frames(over: 500)
        // Three shaders (the capsule, Back, Compose) in one tick, ~20 a second.
        XCTAssertGreaterThan(moving, 12, "it isn't moving")
        XCTAssertLessThanOrEqual(moving, 3 * 17, "more than about 30 frames a second")

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        let background = try await frames(over: 400)
        XCTAssertEqual(background, 0, "drawn in the background")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let back = try await frames(over: 400)
        XCTAssertGreaterThan(back, 0, "it didn't come back")

        let over = UIViewController()
        navigation.pushViewController(over, animated: false)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let covered = try await frames(over: 400)
        XCTAssertEqual(covered, 0, "drawn under another screen")
        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        try await until { header.backdrop.shader.window != nil }
        let shown = try await frames(over: 400)
        XCTAssertGreaterThan(shown, 0)

        // Off again: still.
        LiveAvatars.isEnabled = false
        try await Task.sleep(for: .milliseconds(150))
        let off = try await frames(over: 400)
        XCTAssertEqual(off, 0)
    }
}
#endif
