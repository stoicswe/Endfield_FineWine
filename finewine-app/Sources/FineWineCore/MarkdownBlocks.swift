import Foundation

/// The block structure of a Markdown text, as release notes on GitHub use it: headings,
/// paragraphs, lists, quotes, code, tables and rules. What is inside a block (bold, links,
/// `code`) stays Markdown text, which `AttributedString(markdown:)` renders.
///
/// This is not a full Markdown parser. It covers what GitHub release descriptions are written
/// in, and anything it does not know is shown as a paragraph, so nothing is lost.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// One list: each item with how deep it is nested (0 for the outermost) and, for a
    /// numbered item, its number as written.
    case list([ListItem])
    /// A quote; its content is parsed as blocks again.
    case quote([MarkdownBlock])
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Equatable, Sendable {
        public var depth: Int
        public var marker: String       // "•" or "1."
        public var text: String

        public init(depth: Int, marker: String, text: String) {
            self.depth = depth
            self.marker = marker
            self.text = text
        }
    }
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return parse(lines: lines)
    }

    private static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // ``` code ```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1      // the closing fence, when there is one
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // # heading
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // --- rule
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // > quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var content = current.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    inner.append(String(content))
                    index += 1
                }
                blocks.append(.quote(parse(lines: inner)))
                continue
            }

            // | table |
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix("|") else { break }
                    rows.append(cells(current))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // - list
            if listItem(line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.ListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(current) {
                        items.append(item)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix(" "), !items.isEmpty {
                        // a line that continues the item above
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            // Two spaces at the end of a line are a line break in Markdown; here the lines of a
            // paragraph are joined by a space either way, which reads the same in a notes view.
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).hasPrefix(" ") else { return nil }
        var text = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "- text", "* text", "+ text", "1. text", "1) text", with any indentation.
    private static func listItem(_ line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first else { return nil }
        if "-*+".contains(first), rest.dropFirst().hasPrefix(" ") {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // "- [ ]" and "- [x]" task items keep their box as text
            return .init(depth: width / 2, marker: "•", text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4 {
            let after = rest.dropFirst(digits.count)
            if (after.hasPrefix(". ") || after.hasPrefix(") ")) {
                return .init(depth: width / 2, marker: "\(digits).", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
