import AppKit
import Markdown

/// Converts Markdown's parsed tree directly into native text attributes.
/// No HTML importer, web view, remote images, or syntax matching is involved.
struct MarkdownRenderer {
    static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    func render(_ source: String) -> NSAttributedString {
        var visitor = AttributedStringVisitor(source: source)
        // Translation punctuation and code-like text must not be smartened.
        let result = visitor.visit(Document(parsing: source, options: [.disableSmartOpts]))
        // Keep boundary whitespace verbatim for ordinary streamed prose. Escapes
        // and entities still use the parser's decoded text, even without styling.
        if !visitor.hasFormatting,
           result.string.trimmingCharacters(in: .whitespacesAndNewlines)
            == source.trimmingCharacters(in: .whitespacesAndNewlines) {
            return NSAttributedString(string: source, attributes: Self.textAttributes)
        }
        return result
    }

    static func plainText(from rendered: NSAttributedString, in selection: NSRange? = nil) -> String {
        let source = rendered.string as NSString
        let selection = selection ?? NSRange(location: 0, length: source.length)
        let selectionEnd = NSMaxRange(selection)
        var result = ""
        rendered.enumerateAttribute(.paragraphStyle, in: selection) { value, range, _ in
            let end = NSMaxRange(range)
            // AppKit needs a paragraph terminator in every cell. Keep table
            // rows together when copying them as plain text.
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  source.character(at: end - 1) == 0x0A else {
                result += source.substring(with: range)
                return
            }
            if end == selectionEnd && end < source.length {
                // A selection may stop at a real line break inside the cell.
                let nextStyle = rendered.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle
                if nextStyle?.textBlocks.last === cell {
                    result += source.substring(with: range)
                    return
                }
            }
            let hasNextColumn = cell.startingColumn < cell.table.numberOfColumns - 1
            var textRange = range
            if hasNextColumn || end == source.length { textRange.length -= 1 }
            result += source.substring(with: textRange)
            if hasNextColumn && end < selectionEnd { result += "  |  " }
        }
        return result
    }
}

private struct AttributedStringVisitor: MarkupVisitor {
    typealias Result = NSAttributedString

    private let source: String
    private lazy var sourceLines = source.split(omittingEmptySubsequences: false) {
        $0 == "\n" || $0 == "\r" || $0 == "\r\n"
    }
    private var font = NSFont.systemFont(ofSize: 15)
    private var indent: CGFloat = 0
    private var color = NSColor.textColor
    private(set) var hasFormatting = false

    init(source: String) {
        self.source = source
    }

    private var paragraphStyle: NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        if indent > 0 {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }
        return paragraph
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle]
    }

    private func text(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: attributes)
    }

    private mutating func children(of markup: any Markup, separator: String = "") -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        var previousChild: (any Markup)?
        for child in markup.children {
            let rendered = visit(child)
            guard rendered.length > 0 else { continue }
            if let previousChild, !separator.isEmpty {
                let gap = previousChild is Paragraph && child is Paragraph ? "\n\n" : separator
                appendSeparator(gap, to: result)
            }
            result.append(rendered)
            previousChild = child
        }
        return result
    }

    private func appendSeparator(_ separator: String, to result: NSMutableAttributedString) {
        guard result.length > 0 else { return }
        let style = result.attributes(at: result.length - 1, effectiveRange: nil)
        // The final table cell already ends with a paragraph break.
        if (style[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is NSTextTableBlock { return }
        result.append(NSAttributedString(string: separator, attributes: style))
    }

    mutating func defaultVisit(_ markup: any Markup) -> NSAttributedString {
        children(of: markup, separator: markup is any BlockMarkup ? "\n" : "")
    }

    mutating func visitDocument(_ document: Document) -> NSAttributedString {
        children(of: document, separator: "\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let result = children(of: paragraph)
        let string = result.string as NSString
        guard string.length > 0 else { return result }
        let lastLine = string.paragraphRange(for: NSRange(location: string.length - 1, length: 0))
        if lastLine.location > 0 {
            // Preserve explicit line breaks without adding a paragraph gap.
            let lineStyle = paragraphStyle
            lineStyle.paragraphSpacing = 0
            result.addAttribute(.paragraphStyle, value: lineStyle, range: NSRange(location: 0, length: lastLine.location))
        }
        return result
    }

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString { self.text(text.string) }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString { text("\n") }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString { text("\n") }

    private mutating func styledChildren(_ markup: any Markup, trait: NSFontDescriptor.SymbolicTraits) -> NSAttributedString {
        hasFormatting = true
        let previous = font
        font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)), size: font.pointSize) ?? font
        defer { font = previous }
        return children(of: markup)
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        styledChildren(strong, trait: .bold)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        styledChildren(emphasis, trait: .italic)
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        hasFormatting = true
        let previous = font
        let sizes: [CGFloat] = [26, 23, 20, 18, 16, 15]
        font = .systemFont(ofSize: sizes[min(max(heading.level, 1), 6) - 1], weight: .bold)
        defer { font = previous }
        let result = children(of: heading)
        let paragraph = paragraphStyle
        paragraph.headerLevel = heading.level
        paragraph.paragraphSpacingBefore = 8
        paragraph.paragraphSpacing = 10
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        hasFormatting = true
        var style = attributes
        let mono = NSFont.monospacedSystemFont(ofSize: max(12, font.pointSize - 1), weight: .regular)
        let traits = mono.fontDescriptor.symbolicTraits.union(font.fontDescriptor.symbolicTraits)
        style[.font] = NSFont(descriptor: mono.fontDescriptor.withSymbolicTraits(traits), size: mono.pointSize) ?? mono
        style[.backgroundColor] = NSColor.quaternaryLabelColor
        return NSAttributedString(string: inlineCode.code, attributes: style)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        hasFormatting = true
        var style = attributes
        style[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        style[.backgroundColor] = NSColor.quaternaryLabelColor
        let paragraph = paragraphStyle
        paragraph.firstLineHeadIndent = indent + 10
        paragraph.headIndent = indent + 10
        paragraph.tailIndent = -10
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        style[.paragraphStyle] = paragraph
        // cmark terminates code blocks with a newline; block separators supply it.
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }
        return NSAttributedString(string: code, attributes: style)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> NSAttributedString {
        renderList(orderedList, start: orderedList.startIndex)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> NSAttributedString {
        renderList(unorderedList, start: nil)
    }

    private mutating func renderList(_ list: any Markup, start: UInt?) -> NSAttributedString {
        hasFormatting = true
        let previous = indent
        let items = list.children.compactMap { $0 as? ListItem }
        let markers = items.enumerated().map { offset, item in
            let marker: String
            if let start {
                marker = orderedMarker(for: item) ?? "\(start + UInt(offset))."
            } else {
                marker = "•"
            }
            switch item.checkbox {
            case .checked: return "\(marker) ☑"
            case .unchecked: return "\(marker) ☐"
            case nil: return marker
            }
        }
        let markerWidth = markers.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        indent += max(24, ceil(markerWidth) + 10)
        defer { indent = previous }
        let result = NSMutableAttributedString(string: "")
        for (item, marker) in zip(items, markers) {
            appendSeparator("\n", to: result)
            let content = children(of: item, separator: "\n")
            let firstStyle = content.length > 0
                ? content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                : nil
            if firstStyle?.textBlocks.last is NSTextTableBlock {
                // A table at the start of an item must keep its first cell.
                var markerStyle = attributes
                let paragraph = paragraphStyle
                paragraph.firstLineHeadIndent = previous
                markerStyle[.paragraphStyle] = paragraph
                result.append(NSAttributedString(string: marker + "\n", attributes: markerStyle))
                result.append(content)
                continue
            }
            let paragraph = firstStyle?.mutableCopy() as? NSMutableParagraphStyle ?? paragraphStyle
            paragraph.firstLineHeadIndent = previous
            let prefix = NSMutableAttributedString(attributedString: text(marker + "\t"))
            prefix.append(content)
            // Only the first paragraph carries a marker. Continuation blocks
            // and nested lists keep the indentation assigned by their visitor.
            let firstParagraph = (prefix.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            prefix.addAttribute(.paragraphStyle, value: paragraph, range: firstParagraph)
            result.append(prefix)
        }
        return result
    }

    private mutating func orderedMarker(for item: ListItem) -> String? {
        // cmark exposes only the list's first number. Read the marker at the
        // AST item's source position to preserve numbering gaps and delimiters.
        guard let position = item.range?.lowerBound,
              sourceLines.indices.contains(position.line - 1), position.column > 0 else { return nil }
        let line = sourceLines[position.line - 1].utf8.dropFirst(position.column - 1)
        let digits = line.prefix { (48...57).contains($0) }
        guard !digits.isEmpty, let delimiter = line.dropFirst(digits.count).first,
              delimiter == 46 || delimiter == 41 else { return nil }
        return String(decoding: line.prefix(digits.count + 1), as: UTF8.self)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        hasFormatting = true
        let previousIndent = indent
        let previousColor = color
        indent += 16
        color = .secondaryLabelColor
        defer { indent = previousIndent; color = previousColor }
        return children(of: blockQuote, separator: "\n")
    }

    mutating func visitLink(_ link: Markdown.Link) -> NSAttributedString {
        hasFormatting = true
        let result = children(of: link)
        if let destination = link.destination, let url = URL(string: destination),
           let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
            let range = NSRange(location: 0, length: result.length)
            result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return result
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        hasFormatting = true
        let result = children(of: strikethrough)
        result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: result.length))
        return result
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        hasFormatting = true
        return text("────────────")
    }

    // Images display their alternative text; HTML remains literal selectable
    // text. Neither path fetches resources or interprets executable markup.
    mutating func visitImage(_ image: Markdown.Image) -> NSAttributedString {
        hasFormatting = true
        return children(of: image)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> NSAttributedString { text(inlineHTML.rawHTML) }
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> NSAttributedString { text(html.rawHTML) }

    mutating func visitTable(_ table: Table) -> NSAttributedString {
        hasFormatting = true
        let columnCount = table.maxColumnCount
        let padding = min(4, 24 / CGFloat(columnCount))
        let grid = ResultTextTable()
        grid.numberOfColumns = columnCount
        grid.layoutAlgorithm = .fixedLayoutAlgorithm
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        grid.setWidth(indent, type: .absolute, for: .margin, edge: .minX)
        let alignments = table.columnAlignments.map { alignment -> NSTextAlignment in
            switch alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            case nil: .natural
            }
        }

        let previous = font
        defer { font = previous }
        let result = NSMutableAttributedString(string: "")
        let rows: [any Markup] = [table.head] + Array(table.body.children)
        for (rowIndex, row) in rows.enumerated() {
            let isHeader = rowIndex == 0
            font = isHeader ? .boldSystemFont(ofSize: previous.pointSize) : previous
            var cells = row.children.makeIterator()
            for column in 0..<columnCount {
                let content = cells.next().map { children(of: $0) } ?? NSMutableAttributedString(string: "")
                let cell = NSTextTableBlock(table: grid, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(0.5, type: .absolute, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(padding, type: .absolute, for: .padding)
                if isHeader { cell.backgroundColor = .quaternaryLabelColor }
                let style = NSMutableParagraphStyle()
                style.alignment = alignments[column]
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = 2
                style.textBlocks = [cell]
                content.append(text("\n"))
                content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
        return result
    }
}
