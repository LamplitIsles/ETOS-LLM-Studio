import Foundation
import Markdown

/// The effective image destination, using UTF-8 bytes to preserve literal paths.
public enum CFLMarkdownImageTarget: Equatable, Sendable {
    case workspace(Data), external(Data), api(Data), unavailable, ambiguous
}

/// Maps MarkdownUI provider URLs back to the image source supplied by cmark.
/// Build this from the same message text rendered by MarkdownUI; a missing or
/// ambiguous result must be treated as unavailable, never guessed from the URL.
public struct CFLMarkdownImageSources: Sendable {
    private enum Entry: Sendable {
        case source(String)
        case ambiguous
    }
    private let entries: [Data: Entry]

    public init(markdown: String) {
        var collector = Collector()
        collector.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        entries = collector.entries
    }

    public func source(for url: URL) -> String? {
        guard case .source(let source) = entries[Data(url.absoluteString.utf8)] else { return nil }
        return source
    }

    /// Compare original destinations, never decoded paths. Different spellings
    /// are equivalent only when both resolve to the same literal workspace path.
    /// Identical external and API sources remain eligible for their normal loaders.
    public static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = CFLMarkdownImage.resolve(lhs)
        if lhs.utf8.elementsEqual(rhs.utf8) { return left != .invalid }
        guard case .workspace(let leftPath) = left,
              case .workspace(let rightPath) = CFLMarkdownImage.resolve(rhs) else { return false }
        return leftPath.utf8.elementsEqual(rightPath.utf8)
    }

    /// Effective targets of images actually parsed in a chunk, in document order.
    /// Reference definitions must be present in the chunk for its parser to resolve them.
    public func targets(in markdown: String) -> [CFLMarkdownImageTarget] {
        var collector = TargetCollector(sources: self)
        collector.visit(Document(parsing: markdown, options: [.disableSmartOpts]))
        return collector.targets
    }

    private struct TargetCollector: MarkupWalker {
        let sources: CFLMarkdownImageSources
        var targets: [CFLMarkdownImageTarget] = []

        mutating func visitImage(_ image: Markdown.Image) {
            targets.append(target(for: image.source))
            descendInto(image)
        }

        private func target(for chunkSource: String?) -> CFLMarkdownImageTarget {
            guard let chunkSource, let url = URL(string: chunkSource, relativeTo: nil) else { return .unavailable }
            switch sources.entries[Data(url.absoluteString.utf8)] {
            case .ambiguous: return .ambiguous
            case .source(let source):
                guard CFLMarkdownImageSources.areEquivalent(source, chunkSource) else { return .unavailable }
                switch CFLMarkdownImage.resolve(source) {
                case .workspace(let path): return .workspace(Data(path.utf8))
                case .external: return .external(Data(source.utf8))
                case .api: return .api(Data(source.utf8))
                case .invalid: return .unavailable
                }
            case nil: return .unavailable
            }
        }
    }

    private struct Collector: MarkupWalker {
        var entries: [Data: Entry] = [:]

        mutating func visitImage(_ image: Markdown.Image) {
            if let source = image.source, let url = URL(string: source, relativeTo: nil) {
                let key = Data(url.absoluteString.utf8)
                switch entries[key] {
                case nil:
                    entries[key] = .source(source)
                case .source(let previous) where !CFLMarkdownImageSources.areEquivalent(previous, source):
                    entries[key] = .ambiguous
                default:
                    break
                }
            }
            descendInto(image)
        }
    }
}
