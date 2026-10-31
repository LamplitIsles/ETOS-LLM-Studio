import Foundation
import Markdown

/// Projects an authoritative reply into display-only source spans.
nonisolated enum CFLReplyPresentation {
    private static let quotePrefix = try! NSRegularExpression(pattern: "(?m)^ {0,3}>[ \\t]?")
    private static let inlineOpening = try! NSRegularExpression(
        pattern: #"(?<!\\)(\*\*|__|(?<![\p{L}\p{N}])[*_](?=\S)|`+|\[)"#
    )
    private static let referenceDefinition = try! NSRegularExpression(
        pattern: #"(?m)^ {0,3}\[[^\]\r\n]+\]:[ \t]*\S"#
    )
    struct Chunk: Equatable, Identifiable, Sendable {
        let id: Int // UTF-16 source offset; stable while a reply grows.
        let text: String
    }

    static func visibleSource(_ text: String, streaming: Bool) -> String {
        guard streaming else { return text }
        let source = text as NSString
        let newline = source.range(of: "\n", options: .backwards)
        guard newline.location != NSNotFound else { return "" }
        return source.substring(to: newline.location + newline.length)
    }

    static func chunks(_ source: String) -> [Chunk] {
        let text = source as NSString
        guard text.length > 0 else { return [] }
        // Rendering each fragment independently loses definitions elsewhere in
        // the source. Keep that uncommon case together so links stay usable.
        if referenceDefinition.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) != nil {
            return [Chunk(id: 0, text: source)]
        }
        var lineStarts = [0]
        var scan = 0
        while scan < text.length {
            let newline = text.range(of: "\n", range: NSRange(location: scan, length: text.length - scan))
            guard newline.location != NSNotFound else { break }
            scan = newline.location + newline.length
            lineStarts.append(scan)
        }

        // Markdown nodes spanning several lines must stay together. Paragraphs
        // and quotes may be split at their source lines; their nested inline
        // nodes still protect a multi-line link or emphasis span.
        var protectedLines = Set<Int>()
        func visit(_ node: any Markup) {
            if node is Paragraph, let range = node.range {
                let first = max(1, range.lowerBound.line)
                let last = min(lineStarts.count, range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0))
                if first <= last {
                    let start = lineStarts[first - 1]
                    let end = last < lineStarts.count ? lineStarts[last] : text.length
                    let section = NSRange(location: start, length: end - start)
                    var consumed = start
                    for match in inlineOpening.matches(in: source, range: section) where match.range.location >= consumed {
                        let marker = text.substring(with: match.range)
                        let close = marker == "[" ? "]" : marker
                        let after = NSMaxRange(match.range)
                        let closing = text.range(of: close, range: NSRange(location: after, length: end - after))
                        var incomplete = closing.location == NSNotFound
                        if !incomplete {
                            consumed = NSMaxRange(closing)
                            if marker == "[", consumed < end, text.character(at: consumed) == 40 {
                                let target = text.range(of: ")", range: NSRange(location: consumed + 1, length: end - consumed - 1))
                                incomplete = target.location == NSNotFound
                                if !incomplete { consumed = NSMaxRange(target) }
                            }
                        }
                        if incomplete {
                            let openingLine = (first...last).last { lineStarts[$0 - 1] <= match.range.location } ?? first
                            if openingLine < last {
                                for line in openingLine..<last { protectedLines.insert(line) }
                            }
                            break
                        }
                    }
                }
            }
            if !(node is Document || node is Paragraph || node is BlockQuote),
               let range = node.range {
                let lastLine = range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0)
                if lastLine > range.lowerBound.line {
                    for line in range.lowerBound.line..<lastLine { protectedLines.insert(line) }
                }
            }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: source))

        var chunks: [Chunk] = []
        var start = 0
        var line = 1
        var cursor = 0
        while cursor < text.length {
            let found = text.range(of: "\n", range: NSRange(location: cursor, length: text.length - cursor))
            let end = found.location == NSNotFound ? text.length : found.location + found.length
            if found.location == NSNotFound || !protectedLines.contains(line) {
                let part = text.substring(with: NSRange(location: start, length: end - start))
                let range = NSRange(location: 0, length: (part as NSString).length)
                let content = quotePrefix.stringByReplacingMatches(in: part, range: range, withTemplate: "")
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(Chunk(id: start, text: part))
                    start = end
                } else if let previous = chunks.popLast() {
                    chunks.append(Chunk(id: previous.id, text: previous.text + part))
                    start = end
                }
            }
            cursor = end
            line += 1
        }
        return chunks
    }
}
