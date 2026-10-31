#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit
import UltraView

/// What one row of home's list draws as a bitmap, on UltraView's display
/// queue: the hairline under it, its title, a heading's title, the
/// trailing question or clock, a fold's chevron, and a story row's time,
/// status, draft and empty mark. Everything else a row shows stays a view
/// of `SidebarItemView`: the card's fill and a finger's highlight under the
/// bitmap, and the mark, the story ring and the working signal over it.
///
/// It draws what `RowView` lays out with labels, in the same faces,
/// colours and frames, as those labels would draw it: one line centred on
/// its box and cut at the tail, a status's lines from their box's top. It
/// holds only values, and decides nothing about where anything goes.
struct SidebarItemDrawing: Drawing, Equatable {
    var row: Row
    /// The row's frames, from its slot's top-left (`SidebarLayout.local`).
    var frame: SidebarLayout.Frame
    var selected: Bool
    var dark: Bool
    /// The screen's pixels per point, for whole-pixel text boxes.
    var displayScale: CGFloat
    /// The person's text size, which story rows are drawn at.
    var textScale: CGFloat
    /// The minute a story row's time is read at.
    var now: Date

    func draw(in context: CGContext, bounds: CGRect) {
        #if DEBUG || HAPPY_FIXTURES
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        // The tokens' dynamic colours resolve for this row's appearance.
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent { drawContent() }
    }

    private func drawContent() {
        if let line = frame.cell?.separator {
            UIColor(Palette.groupedSeparator).setFill()
            UIRectFill(line)
        }
        switch row.kind {
        case .separator:
            return
        case .section:
            // iOS's section header: small capitals in the quiet grey.
            let title = NSAttributedString(string: row.label.uppercased(), attributes: [
                .font: RowView.groupedHeadingFont,
                .kern: GroupedSidebarMetrics.headingSize * RowView.groupedHeadingTracking,
                .foregroundColor: UIColor(Palette.settingsSecondary),
            ])
            Self.drawLine(title, in: frame.label, scale: displayScale)
            if row.collapsed != nil, let glyph = frame.chevronGlyph {
                Self.drawGlyph(chevron(GroupedSidebarMetrics.headingGlyph), color: UIColor(Palette.settingsSecondary), in: glyph)
            }
            return
        default:
            break
        }
        Self.drawLine(title, in: frame.label, scale: displayScale)
        if (row.kind == .space || row.kind == .session) && row.collapsed != nil, let glyph = frame.chevronGlyph {
            Self.drawGlyph(chevron(row.amongStories ? StoryRowMetrics.headingGlyph : Metrics.chevronGlyph), color: UIColor(Palette.rowText), in: glyph)
        }
        if row.story == nil {
            drawTrailing()
        } else {
            drawStory()
        }
    }

    /// A row's title in its font and ink (a dynamic colour, resolved where
    /// it is drawn). A story row's keeps one weight: unread is its corner's
    /// to say.
    var title: NSAttributedString {
        let font = row.story != nil ? StoryRowText.titleFont(textScale) : Fonts.ui(row.unread || row.isNew ? .bold : selected ? .semiBold : .medium, size: Metrics.labelSize)
        let ink = UIColor(selected || row.unread || row.isNew || row.story != nil ? Palette.rowTextActive : Palette.rowText)
        return NSAttributedString(string: row.label, attributes: [.font: font, .foregroundColor: ink])
    }

    /// `Glyphs.image` at this screen's pixels.
    private func glyph(_ name: String, size: CGFloat) -> UIImage {
        UIImage.icon(Glyphs.icon(name), size: size, scale: displayScale)
    }

    private func chevron(_ size: CGFloat) -> UIImage {
        glyph(row.collapsed == true || row.hasHiddenSessions ? "chevron-right" : "chevron-down", size: size)
    }

    /// The question, the clock or a new row's dot in the trailing square.
    private func drawTrailing() {
        guard let trailing = frame.trailing else { return }
        switch row.status {
        case .awaitingInput:
            Self.drawGlyph(glyph("question", size: Metrics.questionGlyph), color: UIColor(Palette.rowText), in: trailing)
        case .waiting:
            Self.drawGlyph(glyph("clock", size: Metrics.clockGlyph), color: UIColor(Palette.rowText), in: trailing)
        case .working, .none:
            guard row.isNew else { return }
            UIColor(Palette.rowNewDot).setFill()
            let dot = CGRect(x: trailing.midX - Metrics.newDot / 2, y: trailing.midY - Metrics.newDot / 2, width: Metrics.newDot, height: Metrics.newDot)
            UIBezierPath(ovalIn: dot).fill()
        }
    }

    /// The time, the status in up to two lines or one and the draft, or the
    /// empty mark.
    private func drawStory() {
        let last = StoryRowText.lastLine(row)
        if let box = frame.time, let time = StoryRowText.time(row, now: now) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byTruncatingTail
            Self.drawLine(NSAttributedString(string: time, attributes: [.font: StoryRowText.timeFont(textScale), .foregroundColor: UIColor(Palette.rowText), .paragraphStyle: paragraph]), in: box, scale: displayScale)
        }
        if let box = frame.subtitle {
            Self.drawTop(StoryRowText.status(row, scale: textScale), in: box, lines: last == .status ? StoryRowMetrics.statusLines : 1, scale: displayScale)
        }
        if last == .draft, let box = frame.draft, let draft = row.draft {
            Self.drawLine(StoryRowText.draft(draft, scale: textScale), in: box, scale: displayScale)
        }
        if last == .empty, let box = frame.empty, box.width > 0, box.height > 0 {
            let image = EmptyMarkView.image(size: box.size, scale: displayScale)
            let context = UIGraphicsGetCurrentContext()
            context?.saveGState()
            context?.interpolationQuality = .none
            image.withTintColor(UIColor(Palette.rowText).withAlphaComponent(StoryRowMetrics.emptyInk), renderingMode: .alwaysOriginal).draw(in: CGRect(origin: box.origin, size: image.size))
            context?.restoreGState()
        }
    }

    // MARK: As UIKit draws them

    /// One line as a label draws it: cut at the tail, and centred on its
    /// box's height on the label's own text height.
    static func drawLine(_ text: NSAttributedString, in box: CGRect, scale: CGFloat) {
        guard box.width > 0, text.length > 0 else { return }
        let line = NSMutableAttributedString(attributedString: text)
        line.addParagraphLineBreak(.byTruncatingTail)
        let measured = line.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        // A label's text is whole points tall, centred in its own box on
        // the pixel above, wherever the box is.
        let height = min(box.height, measured.height.rounded(.up))
        let y = box.minY + pixelFloor((box.height - height) / 2, scale)
        line.draw(with: CGRect(x: box.minX, y: y, width: box.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// `lines` lines at most from the box's top, the last one cut at the
    /// tail, as a `TopLabel` draws them.
    static func drawTop(_ text: NSAttributedString, in box: CGRect, lines: Int, scale: CGFloat) {
        guard box.width > 0, text.length > 0 else { return }
        let block = NSMutableAttributedString(attributedString: text)
        block.addParagraphLineBreak(lines == 1 ? .byTruncatingTail : .byWordWrapping)
        let measured = block.boundingRect(with: CGSize(width: box.width, height: box.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        let height = min(box.height, pixelCeil(measured.height, scale))
        block.draw(with: CGRect(x: box.minX, y: box.minY, width: box.width, height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// A template image tinted `color`, in the middle of `box` at its own
    /// size, as an image view centres it.
    static func drawGlyph(_ image: UIImage, color: UIColor, in box: CGRect) {
        let size = image.size
        let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        image.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: rect)
    }

    private static func pixelFloor(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        // A hair over, so a pixel's own edge stays that pixel.
        scale > 0 ? (value * scale + 0.001).rounded(.down) / scale : (value + 0.001).rounded(.down)
    }

    private static func pixelCeil(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        scale > 0 ? (value * scale).rounded(.up) / scale : value.rounded(.up)
    }
}

private extension NSMutableAttributedString {
    /// Every paragraph breaks its lines `mode`, keeping its other settings.
    func addParagraphLineBreak(_ mode: NSLineBreakMode) {
        let whole = NSRange(location: 0, length: length)
        var runs: [(NSRange, NSParagraphStyle?)] = []
        enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in runs.append((range, value as? NSParagraphStyle)) }
        for (range, style) in runs {
            let paragraph = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.lineBreakMode = mode
            addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
}
#endif
