import AppKit

/// TextKit 1 lays out tables and prose in one selectable document. Give prose
/// the viewport width even when a table makes the document wider.
final class ResultTextContainer: NSTextContainer {
    var viewportWidth = CGFloat.greatestFiniteMagnitude {
        didSet {
            if viewportWidth != oldValue && min(viewportWidth, oldValue) < size.width {
                layoutManager?.textContainerChangedGeometry(self)
            }
        }
    }

    override var isSimpleRectangularTextContainer: Bool {
        viewportWidth >= size.width && super.isSimpleRectangularTextContainer
    }

    override func lineFragmentRect(
        forProposedRect proposedRect: NSRect,
        at characterIndex: Int,
        writingDirection: NSWritingDirection,
        remaining remainingRect: NSRectPointer?
    ) -> NSRect {
        var rect = proposedRect
        if viewportWidth < size.width {
            let storage = layoutManager?.textStorage
            let style = storage.flatMap { storage in
                characterIndex < storage.length
                    ? storage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil) as? NSParagraphStyle
                    : nil
            }
            if !(style?.textBlocks.last is NSTextTableBlock) {
                rect.size.width = min(rect.width, max(0, viewportWidth - rect.minX))
            }
        }
        return super.lineFragmentRect(forProposedRect: rect, at: characterIndex, writingDirection: writingDirection, remaining: remainingRect)
    }
}

final class ResultTextTable: NSTextTable {
    var minimumLayoutWidth: CGFloat {
        // Leave room for a full-width character or emoji, plus cell insets.
        40 * CGFloat(numberOfColumns) + width(for: .margin, edge: .minX)
    }

    override func rect(
        for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
        textContainer: NSTextContainer, characterRange: NSRange
    ) -> NSRect {
        super.rect(for: block, layoutAt: startingPoint, in: fittedRect(rect, in: textContainer),
                   textContainer: textContainer, characterRange: characterRange)
    }

    override func boundsRect(
        for block: NSTextTableBlock, contentRect: NSRect, in rect: NSRect,
        textContainer: NSTextContainer, characterRange: NSRange
    ) -> NSRect {
        super.boundsRect(for: block, contentRect: contentRect, in: fittedRect(rect, in: textContainer),
                         textContainer: textContainer, characterRange: characterRange)
    }

    private func fittedRect(_ rect: NSRect, in textContainer: NSTextContainer) -> NSRect {
        guard let container = textContainer as? ResultTextContainer else { return rect }
        let viewport = container.viewportWidth - 2 * container.lineFragmentPadding
        var fitted = rect
        fitted.size.width = min(rect.width, max(viewport, minimumLayoutWidth))
        return fitted
    }
}
