#if canImport(UIKit) && (DEBUG || HAPPY_FIXTURES)
import HappyLayout
@testable import HappyUI
import UIKit

/// The chat header's shader looks side by side (`-screen pillShaders`): one
/// row per `ChatPillShader.candidates` and one plain, each a stand-in header
/// (a glass circle for Back, the real title capsule, a glass circle for
/// Compose) over a transcript of light text, dark blocks and bright pictures
/// that keeps scrolling under them. `-seed S` picks the chat; `-dark` is
/// dark mode; `-still` holds the shader and the content. Animated Avatars
/// is on for the run, so the shaders move. Prints each row's capsule in
/// window points (`PILL row x y w h`), for reading the pixels.
@MainActor
final class PillShaderHarness {
    private let content = UIScrollView()
    private var link: CADisplayLink?
    private var offset: CGFloat = 0
    private var last: CFTimeInterval?

    init(window: UIWindow, arguments: [String]) {
        window.overrideUserInterfaceStyle = arguments.contains("-dark") ? .dark : .light
        let seed = arguments.firstIndex(of: "-seed").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "chat-header"
        let still = arguments.contains("-still")
        LiveAvatars.isEnabled = !still
        let root = UIViewController()
        root.view.backgroundColor = UIColor(Palette.background)
        window.rootViewController = root
        window.layoutIfNeeded()
        let bounds = root.view.bounds

        content.frame = bounds
        content.isUserInteractionEnabled = false
        root.view.addSubview(content)
        var y: CGFloat = 0
        let width = bounds.width
        // One ground under every row, held still, for comparing them.
        let ground = arguments.firstIndex(of: "-ground").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let kinds: [Int] = switch ground {
        case "plain": []
        case "text": Array(repeating: 0, count: 40)
        case "dark": [1]
        case "picture": [2]
        default: (0..<60).map { $0 % 3 }
        }
        for kind in kinds {
            let view: UIView
            switch kind {
            case 0:
                let label = UILabel()
                label.numberOfLines = 0
                label.font = LegacyFonts.font(.regular, size: 16)
                label.textColor = UIColor(Palette.text)
                label.text = "Telegram draws the back button, the title and the right button each on their own piece of glass, and the messages scroll under all of them, fading out behind the bar just before they reach the glass."
                label.frame = CGRect(x: 16, y: 0, width: width - 32, height: label.sizeThatFits(CGSize(width: width - 32, height: 400)).height + 24)
                view = UIView(frame: CGRect(x: 0, y: 0, width: width, height: label.frame.height))
                view.addSubview(label)
            case 1:
                view = UIView(frame: CGRect(x: 0, y: 0, width: width, height: ground == nil ? 140 : bounds.height))
                view.backgroundColor = UIColor(white: 0.08, alpha: 1)
                let label = UILabel(frame: view.bounds.insetBy(dx: 16, dy: 16))
                label.numberOfLines = 0
                label.textColor = .white
                label.font = LegacyFonts.font(.regular, size: 15)
                label.text = "let header = ChatHeaderView() // code on a dark block"
                view.addSubview(label)
            default:
                let gradient = CAGradientLayer()
                gradient.frame = CGRect(x: 0, y: 0, width: width, height: ground == nil ? 180 : bounds.height)
                gradient.colors = [UIColor.systemOrange.cgColor, UIColor.systemPink.cgColor, UIColor.systemTeal.cgColor]
                gradient.startPoint = CGPoint(x: 0, y: 0)
                gradient.endPoint = CGPoint(x: 1, y: 1)
                view = UIView(frame: gradient.frame)
                view.layer.addSublayer(gradient)
            }
            view.frame.origin.y = y
            content.addSubview(view)
            y += view.frame.height
        }
        content.contentSize = CGSize(width: width, height: y)

        let rows: [(String, ChatPillShader.Style?)] = [("plain glass", nil)] + ChatPillShader.candidates.map { ($0.name, $0.style) }
        let top = window.safeAreaInsets.top + 8
        for (index, (name, style)) in rows.enumerated() {
            let row = UIView(frame: CGRect(x: 0, y: top + CGFloat(index) * 90, width: width, height: 76))
            root.view.addSubview(row)
            let label = UILabel(frame: CGRect(x: 16, y: 0, width: width - 32, height: 16))
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .label
            label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
            label.text = " \(index). \(name)"
            label.sizeToFit()
            row.addSubview(label)
            let bar = UIView(frame: CGRect(x: 0, y: 22, width: width, height: 54))
            row.addSubview(bar)
            let header = ChatHeaderView(frame: CGRect(x: 60, y: 5, width: width - 120, height: ChatHeaderLayout.Metrics.height))
            header.translatesAutoresizingMaskIntoConstraints = true
            header.frame = CGRect(x: 60, y: 5, width: width - 120, height: ChatHeaderLayout.Metrics.height)
            header.titleView.text = "Pineapple poem for the team"
            header.status = "Thinking…"
            bar.addSubview(header)
            for (x, glyph) in [(CGFloat(16), "chevron-back"), (width - 60, "create-outline")] {
                let circle = GlassCapsuleView(interactive: false)
                circle.frame = CGRect(x: x, y: 5, width: 44, height: 44)
                let icon = UIImageView(image: .icon(.ionicons(glyph), size: 22))
                icon.tintColor = UIColor(Palette.text)
                icon.contentMode = .center
                icon.frame = circle.contentView.bounds
                circle.contentView.addSubview(icon)
                bar.addSubview(circle)
                if let style {
                    let backdrop = GlassShaderBackdrop()
                    backdrop.style = style
                    backdrop.canvasView = bar
                    backdrop.seed = seed
                    backdrop.follow(circle)
                }
            }
            if let style {
                header.backdrop.style = style
                header.backdrop.canvasView = bar
                header.shaderSeed = seed
            } else {
                header.shaderSeed = nil
            }
            header.layoutIfNeeded()
            let capsule = header.capsule.convert(header.capsule.bounds, to: window)
            print(String(format: "PILL %d %.1f %.1f %.1f %.1f", index, capsule.minX, capsule.minY, capsule.width, capsule.height))
        }
        guard !still, ground == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The transcript runs under the headers at 80 points a second.
    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard let last else { return }
        offset += CGFloat(link.timestamp - last) * 80
        let span = max(1, content.contentSize.height - content.bounds.height)
        content.contentOffset.y = offset.truncatingRemainder(dividingBy: span)
    }
}
#endif
