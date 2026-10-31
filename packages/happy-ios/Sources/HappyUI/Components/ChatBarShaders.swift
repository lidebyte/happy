#if canImport(UIKit)
import HappyLayout
import UIKit

/// The chat's shader behind the bar's own glass circles, Back and Compose,
/// which the system draws: a `GlassShaderBackdrop` just under the
/// navigation bar (in its navigation controller's view, so the screen
/// scrolling under the bar passes under it) beneath each, which their glass
/// blurs and lights as it does anything behind it. The bar's glass is drawn
/// apart from its own subviews, so one in the bar would cover the glyphs. With the title capsule's
/// (`ChatHeaderView.backdrop`) they are windows onto one shader across the bar. A screen attaches them
/// while it is the bar's top screen and lays them out when the bar is.
@MainActor
final class ChatBarShaders {
    private let back = GlassShaderBackdrop()
    private let compose = GlassShaderBackdrop()
    private weak var bar: UINavigationBar?

    var seed: String? {
        didSet { for backdrop in [back, compose] { backdrop.seed = seed } }
    }
    var monochrome = false {
        didSet { for backdrop in [back, compose] { backdrop.monochrome = monochrome } }
    }

    init() {
        for backdrop in [back, compose] {
            backdrop.alpha = 0
            backdrop.accessibilityIdentifier = "chat-bar-shader"
        }
    }

    /// Under the bar's items from now on, faded in with `coordinator`'s
    /// transition when there is one.
    func attach(to bar: UINavigationBar, alongside coordinator: UIViewControllerTransitionCoordinator?) {
        self.bar = bar
        guard let host = bar.superview else { return }
        for backdrop in [back, compose] {
            backdrop.canvasView = bar
            if backdrop.superview !== host { host.insertSubview(backdrop, belowSubview: bar) }
        }
        layout()
        let show = { for backdrop in [self.back, self.compose] { backdrop.alpha = 1 } }
        if let coordinator, coordinator.isAnimated {
            coordinator.animate(alongsideTransition: { _ in show() }, completion: { [weak self] _ in self?.layout() })
        } else {
            show()
        }
    }

    /// Off the bar, faded out with `coordinator`'s transition.
    func detach(alongside coordinator: UIViewControllerTransitionCoordinator?) {
        let hide = { for backdrop in [self.back, self.compose] { backdrop.alpha = 0 } }
        let remove = { [weak self] in
            guard let self else { return }
            // Still the bar's top screen's after a cancelled swipe back.
            guard back.alpha == 0 else { return }
            for backdrop in [back, compose] { backdrop.removeFromSuperview() }
        }
        if let coordinator, coordinator.isAnimated {
            coordinator.animate(alongsideTransition: { _ in hide() }, completion: { context in
                if context.isCancelled {
                    for backdrop in [self.back, self.compose] { backdrop.alpha = 1 }
                } else {
                    remove()
                }
            })
        } else {
            hide()
            remove()
        }
    }

    /// Each backdrop under its circle; none where the bar has none.
    func layout() {
        guard let bar, let host = bar.superview else { return }
        let circles = Self.circles(in: bar, excluding: [back, compose])
        let leading = circles.filter { $0.midX < bar.bounds.midX }.min { $0.minX < $1.minX }
        let trailing = circles.filter { $0.midX > bar.bounds.midX }.max { $0.maxX < $1.maxX }
        for (backdrop, frame) in [(back, leading), (compose, trailing)] {
            backdrop.isHidden = frame == nil
            guard let frame = frame.map({ bar.convert($0, to: host) }), backdrop.frame != frame else { continue }
            backdrop.frame = frame
            backdrop.refresh()
        }
    }

    /// The bar's glass circles: what it draws as a round button, a square
    /// as tall as the bar's controls, in the bar's coordinates.
    static func circles(in bar: UINavigationBar, excluding: [UIView]) -> [CGRect] {
        var found: [CGRect] = []
        func visit(_ view: UIView) {
            for subview in view.subviews where !subview.isHidden && subview.alpha > 0.01 && !excluding.contains(subview) {
                if subview is ChatHeaderView { continue }
                let frame = subview.convert(subview.bounds, to: bar)
                if (36...56).contains(frame.width), abs(frame.width - frame.height) < 1, frame.midY > 0, frame.midY < bar.bounds.height {
                    found.append(frame)
                    continue
                }
                visit(subview)
            }
        }
        visit(bar)
        return found
    }
}
#endif
