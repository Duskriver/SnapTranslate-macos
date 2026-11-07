import AppKit
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    struct ResultLayoutTests {
        @Test(arguments: [NSScroller.Style.overlay, .legacy])
        func translationWrapsWithinViewportWhileStreamingAndResizing(style: NSScroller.Style) throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            scroll.scrollerStyle = style
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let container = try #require(text.textContainer)
            // Reading layoutManager would switch to TextKit 1 and change the
            // production layout path this regression test is meant to exercise.
            let layout = try #require(text.textLayoutManager)
            let paragraph = "这是一段用于检查译文自动换行的中文内容，混合 English words、代码 profileBundle 和 emoji 👩‍💻。"
                + "https://example.invalid/" + String(repeating: "long_identifier_", count: 50) + "\n"
            var expected = ""

            for width: CGFloat in [440, 584, 340, 900, 440] {
                window.setContentSize(NSSize(width: width, height: 354))
                content.layoutSubtreeIfNeeded()
                for fragment in [paragraph, paragraph] {
                    controller.append(delta: fragment)
                    expected += fragment
                    layout.ensureLayout(for: layout.documentRange)
                    #expect(text.string == expected)
                    #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
                    #expect(abs(scroll.contentView.bounds.minX) < 1)
                    #expect(abs(container.containerSize.width - (scroll.contentSize.width - 2 * text.textContainerInset.width)) < 1)
                    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                        for line in fragment.textLineFragments {
                            let bounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + text.textContainerOrigin.x, dy: 0)
                            #expect(bounds.minX >= 0)
                            #expect(bounds.maxX <= scroll.contentSize.width + 1)
                        }
                        return true
                    }
                }
            }
            controller.finish()
            #expect(text.string == expected)
        }

        @Test func tilingRepairsAnOversizedDocumentAndHorizontalOffset() throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            controller.append(delta: String(repeating: "译文应完整显示，缩放窗口时自动换行。\n", count: 30))
            text.setSelectedRange(NSRange(location: 2, length: 4))
            // Reproduce the mismatched geometry: a document wider than its
            // viewport, with content scrolled sideways despite no scroller.
            text.setFrameSize(NSSize(width: scroll.contentSize.width + 300, height: text.frame.height))
            scroll.contentView.scroll(to: NSPoint(x: 150, y: 40))
            try #require(scroll.contentView.bounds.minX > 0)
            scroll.tile()
            #expect(text.frame.width == scroll.contentSize.width)
            #expect(scroll.contentView.bounds.minX == 0)
            #expect(text.selectedRange() == NSRange(location: 2, length: 4))
        }

        @Test func renderedMarkdownWrapsWithinViewportOnResize() throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let layout = try #require(text.textLayoutManager)
            let longLine = String(repeating: "long_identifier_", count: 40)
            controller.append(delta: "# 标题\n\n- **加粗** " + longLine + "\n  - 嵌套列表内容\n\n```swift\n" + longLine + "\n```")
            controller.finish()
            for width: CGFloat in [340, 584, 440] {
                window.setContentSize(NSSize(width: width, height: 354))
                content.layoutSubtreeIfNeeded()
                layout.ensureLayout(for: layout.documentRange)
                #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
                #expect(abs(scroll.contentView.bounds.minX) < 1)
                layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                    for line in fragment.textLineFragments {
                        let bounds = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + text.textContainerOrigin.x, dy: 0)
                        #expect(bounds.minX >= 0)
                        #expect(bounds.maxX <= scroll.contentSize.width + 1)
                    }
                    return true
                }
            }
        }

        @Test(arguments: [NSScroller.Style.overlay, .legacy])
        func tableColumnsStayAlignedAndCellsWrapOnResize(style: NSScroller.Style) throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            scroll.scrollerStyle = style
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let details = "Long description with words that need to wrap inside the middle cell."
            controller.append(delta: """
                ## 概览

                | Item | Details | Cost |
                | :--- | :--- | ---: |
                | First | \(details) | 19 |
                | Second | | 29 |

                后续正文
                """)
            controller.finish()

            func rect(of value: String) throws -> NSRect {
                let range = (text.string as NSString).range(of: value)
                try #require(range.location != NSNotFound)
                return text.firstRect(forCharacterRange: range, actualRange: nil)
            }

            var rowHeights: [CGFloat] = []
            for width: CGFloat in [340, 740, 340] {
                window.setContentSize(NSSize(width: width, height: 500))
                content.layoutSubtreeIfNeeded()
                let first = try rect(of: "First")
                let middle = try rect(of: "Long")
                let last = try rect(of: "19")
                let next = try rect(of: "Second")
                let footer = try rect(of: "后续正文")
                let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                #expect(abs(first.minY - middle.minY) < 1)
                #expect(abs(first.minY - last.minY) < 1)
                #expect(first.maxX < middle.minX && middle.maxX < last.minX)
                #expect(first.minX >= viewport.minX && last.maxX <= viewport.maxX)
                #expect(next.midY > footer.midY)
                rowHeights.append(first.midY - next.midY)
            }
            #expect(rowHeights[0] > rowHeights[1])
            #expect(abs(rowHeights[0] - rowHeights[2]) < 1)
            let rendered = try #require(text.textStorage)
            #expect(MarkdownRenderer.plainText(from: rendered).contains("Second  |    |  29\n后续正文"))
        }

        @Test(arguments: [NSScroller.Style.overlay, .legacy])
        func wideTablesScrollWhileProseAndSmallTablesFit(style: NSScroller.Style) throws {
            let (controller, scroll, text) = try makeController()
            defer { controller.dismiss() }
            scroll.scrollerStyle = style
            let window = try #require(controller.window)
            let content = try #require(window.contentView)
            let columns = ["甲", "乙"] + Array(repeating: "國", count: 21) + ["末"]
            let delimiter = Array(repeating: "---", count: columns.count)
            func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
            let prose = String(repeating: "段落应该随窗口宽度换行。", count: 24)
            window.setContentSize(NSSize(width: 340, height: 500))
            content.layoutSubtreeIfNeeded()
            controller.append(delta: """
                \(row(columns))
                \(row(delimiter))
                \(row(Array(repeating: "👩‍💻", count: columns.count)))

                | 左 | 右 |
                | --- | --- |
                | First | Last |

                \(prose)
                """)
            controller.finish()

            let string = text.string as NSString
            let layout = try #require(text.layoutManager)
            let container = try #require(text.textContainer)
            func rect(_ value: String) throws -> NSRect {
                let range = string.range(of: value)
                try #require(range.location != NSNotFound)
                layout.ensureLayout(for: container)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                return layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            }
            func viewport() -> NSRect {
                text.convert(scroll.contentView.bounds, from: scroll.contentView)
            }
            func proseLineCount() throws -> Int {
                layout.ensureLayout(for: container)
                let range = string.range(of: prose)
                try #require(range.location != NSNotFound)
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var count = 0
                layout.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
                    #expect(line.maxX + 2 * text.textContainerInset.width <= scroll.contentSize.width + 1)
                    count += 1
                }
                return count
            }

            #expect(scroll.hasHorizontalScroller)
            #expect(scroll.contentView.bounds.minX == 0)
            #expect(text.frame.width > scroll.contentSize.width)
            #expect(try rect("甲").maxX < rect("乙").minX)
            #expect(try rect("末").minX > viewport().maxX)
            #expect(try rect("Last").maxX <= viewport().maxX)
            let narrowLines = try proseLineCount()
            #expect(narrowLines > 1)

            text.scrollRangeToVisible(string.range(of: "末"))
            #expect(scroll.contentView.bounds.minX > 0)
            #expect(try viewport().contains(rect("末").origin))

            window.setContentSize(NSSize(width: 520, height: 500))
            content.layoutSubtreeIfNeeded()
            #expect(scroll.hasHorizontalScroller)
            #expect(scroll.contentView.bounds.minX > 0)
            #expect(try proseLineCount() < narrowLines)

            window.setContentSize(NSSize(width: 1120, height: 500))
            content.layoutSubtreeIfNeeded()
            #expect(!scroll.hasHorizontalScroller)
            #expect(scroll.contentView.bounds.minX == 0)
            #expect(try rect("末").maxX <= viewport().maxX)

            window.setContentSize(NSSize(width: 340, height: 500))
            content.layoutSubtreeIfNeeded()
            #expect(scroll.hasHorizontalScroller)
            controller.showLoading()
            #expect(!scroll.hasHorizontalScroller)
            #expect(text.frame.width == scroll.contentSize.width)
        }

        private func makeController() throws -> (ResultPanelController, NSScrollView, NSTextView) {
            _ = NSApplication.shared
            let controller = ResultPanelController()
            controller.window?.alphaValue = 0
            controller.showLoading()
            let content = try #require(controller.window?.contentView)
            let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
            return (controller, scroll, try #require(scroll.documentView as? NSTextView))
        }
    }
}
