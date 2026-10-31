#if canImport(UIKit)
import HappyLayout
import UIKit

/// A chat's own avatar shader, tinted (`ChatPillShader`), under or inside a
/// piece of the header's glass and cut to its shape. Every piece is a window
/// onto one canvas, the navigation bar it is in (or `canvasView`), so Back,
/// the title and Compose show one shader across the bar. It moves only while
/// Animated Avatars is on and the system lets things move; otherwise it
/// holds the frame its still picture is. Its first frame is drawn in the
/// frame it is laid out in.
final class GlassShaderBackdrop: UIView {
    /// The seed whose placeholder it shows; nil shows nothing.
    var seed: String? {
        didSet { if seed != oldValue { update() } }
    }
    /// The look every new one takes: `ChatPillShader.chosen`, unless a
    /// harness compares another.
    static var defaultStyle = ChatPillShader.chosen

    var style = GlassShaderBackdrop.defaultStyle {
        didSet { if style != oldValue { update() } }
    }
    var monochrome = false {
        didSet { if monochrome != oldValue { update() } }
    }
    /// The canvas it is a window onto; nil, the navigation bar it is in, or
    /// itself.
    weak var canvasView: UIView?

    let shader = LiveAvatarView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        cornerConfiguration = .capsule()
        shader.drawsOnLayout = true
        shader.frame = bounds
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.update() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shader.frame = bounds
        update()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        update()
    }

    /// The navigation bar it sits in, if any.
    private var bar: UINavigationBar? {
        var ancestor = superview
        while let view = ancestor {
            if let bar = view as? UINavigationBar { return bar }
            ancestor = view.superview
        }
        return nil
    }

    func refresh() { update() }

    /// Puts it with `glass`, by `style`: under it, in its frame, or inside
    /// it, under what it carries. Called as the glass is laid out.
    func follow(_ glass: UIVisualEffectView) {
        switch style.placement {
        case .behindGlass:
            guard let host = glass.superview else { return }
            if superview !== host || host.subviews.firstIndex(of: self).map({ $0 > (host.subviews.firstIndex(of: glass) ?? 0) }) == true {
                host.insertSubview(self, belowSubview: glass)
            }
            frame = glass.frame
        case .inGlass:
            if superview !== glass.contentView { glass.contentView.insertSubview(self, at: 0) }
            frame = glass.contentView.bounds
        }
        refresh()
    }

    private func update() {
        // Without a seed nothing is drawn: the view is out of the window.
        guard let seed, AvatarShaderRenderer.shared != nil else {
            shader.removeFromSuperview()
            return
        }
        if shader.superview !== self { addSubview(shader) }
        let canvas = canvasView ?? bar ?? self
        let frame = canvas === self ? bounds : convert(bounds, to: canvas)
        shader.draw(ShaderDrawing(
            index: AvatarPlaceholder.index(seed: seed),
            monochrome: monochrome,
            look: style.look(dark: traitCollection.userInterfaceStyle == .dark),
            speed: style.speed,
            zoom: style.zoom,
            resolution: style.resolution,
            canvas: (frame, canvas.bounds.size),
            followsSetting: true
        ))
    }
}
#endif
