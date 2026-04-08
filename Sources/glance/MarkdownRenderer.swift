import Foundation
import Markdown

enum MarkdownRenderer {
    static func render(_ source: String) -> String {
        let document = Document(parsing: source, options: [.parseBlockDirectives])
        var visitor = HTMLVisitor()
        return visitor.visit(document)
    }
}

/// Renders a source-code file as a single highlighted code block.
/// hljs (already loaded by WebView for fenced markdown blocks) sees the
/// `language-…` class and runs syntax highlighting on it for free.
enum CodeRenderer {
    /// Files larger than this skip highlighting entirely — hljs is fast but
    /// rendering a multi-MB highlighted block in WKWebView gets sluggish.
    private static let highlightSizeLimit = 2 * 1024 * 1024

    static func isCodeFile(_ url: URL) -> Bool {
        language(for: url) != nil
    }

    static func language(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let lang = extensionMap[ext] { return lang }
        let name = url.lastPathComponent.lowercased()
        return filenameMap[name]
    }

    static func render(_ source: String, language: String?) -> String {
        let cls: String
        if source.utf8.count > highlightSizeLimit {
            // hljs respects `no-highlight` and skips the element. The text
            // still renders in the monospace `pre` block, just without colors.
            cls = "no-highlight"
        } else if let language = language {
            cls = "language-\(language)"
        } else {
            cls = "no-highlight"
        }
        let escaped = htmlEscape(source)
        // The page's `main` element is a 720px column tuned for prose. Code
        // files want the full width, so override it with a tiny inline style
        // scoped to this page only.
        return """
        <style>
        main {
            max-width: none !important;
            margin: 0 !important;
            padding: 24px 32px !important;
        }
        pre.glance-codefile {
            margin: 0;
            padding: 0;
            background: transparent;
            border-radius: 0;
            overflow-x: auto;
        }
        pre.glance-codefile code {
            font-size: 0.92em;
        }
        </style>
        <pre class="glance-codefile"><code class="\(cls)">\(escaped)</code></pre>
        """
    }

    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(c)
            }
        }
        return out
    }

    /// Extension → hljs language identifier. Covers the languages most likely
    /// to be opened as a viewer; hljs supports many more, but listing them
    /// all has diminishing returns.
    private static let extensionMap: [String: String] = [
        // Web
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        // Systems
        "c": "c", "h": "c",
        "cpp": "cpp", "cxx": "cpp", "cc": "cpp", "hpp": "cpp", "hxx": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "swift": "swift",
        "rs": "rust",
        "go": "go",
        "zig": "zig",
        // JVM
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "scala": "scala",
        "groovy": "groovy", "gradle": "groovy",
        // Scripting
        "py": "python", "pyw": "python",
        "rb": "ruby",
        "pl": "perl",
        "lua": "lua",
        "r": "r",
        "php": "php",
        "dart": "dart",
        "jl": "julia",
        // Functional
        "hs": "haskell",
        "ml": "ocaml", "mli": "ocaml",
        "ex": "elixir", "exs": "elixir",
        "erl": "erlang",
        "clj": "clojure", "cljs": "clojure",
        "elm": "elm",
        // Shell
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "ps1": "powershell",
        // Data / config
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "ini": "ini", "conf": "ini", "env": "ini",
        "sql": "sql",
        // Build / tools
        "cmake": "cmake",
        "dockerfile": "dockerfile",
        "makefile": "makefile", "mk": "makefile",
        // Markup / other
        "tex": "latex",
        "diff": "diff", "patch": "diff",
        "vim": "vim",
        "proto": "protobuf",
        "graphql": "graphql", "gql": "graphql",
        "nim": "nim",
        "lisp": "lisp",
    ]

    /// Match by full filename for files that don't carry an extension.
    private static let filenameMap: [String: String] = [
        "dockerfile":     "dockerfile",
        "makefile":       "makefile",
        "rakefile":       "ruby",
        "gemfile":        "ruby",
        "podfile":        "ruby",
        "cmakelists.txt": "cmake",
    ]
}

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = heading.children.map { visit($0) }.joined()
        return "<h\(heading.level)>\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(paragraph.children.map { visit($0) }.joined())</p>\n"
    }

    mutating func visitText(_ text: Text) -> String {
        Self.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(emphasis.children.map { visit($0) }.joined())</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(strong.children.map { visit($0) }.joined())</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(strikethrough.children.map { visit($0) }.joined())</del>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? "#"
        let inner = link.children.map { visit($0) }.joined()
        return "<a href=\"\(Self.escapeAttr(dest))\">\(inner)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = image.source ?? ""
        let alt = image.children.map { visit($0) }.joined()
        let title = image.title.map { " title=\"\(Self.escapeAttr($0))\"" } ?? ""
        return "<img src=\"\(Self.escapeAttr(src))\" alt=\"\(alt)\"\(title)>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language.map { " class=\"language-\(Self.escapeAttr($0))\"" } ?? ""
        return "<pre><code\(lang)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(blockQuote.children.map { visit($0) }.joined())</blockquote>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(start)>\n\(orderedList.children.map { visit($0) }.joined())</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(unorderedList.children.map { visit($0) }.joined())</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            let inner = listItem.children.map { visit($0) }.joined()
            return "<li class=\"task\"><input type=\"checkbox\" disabled\(checked)> \(inner)</li>\n"
        }
        return "<li>\(listItem.children.map { visit($0) }.joined())</li>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        " "
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    mutating func visitTable(_ table: Table) -> String {
        var out = "<table>\n"
        out += "<thead>" + visit(table.head) + "</thead>\n"
        out += "<tbody>" + visit(table.body) + "</tbody>\n"
        out += "</table>\n"
        return out
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        "<tr>" + tableHead.children.map { visit($0) }.joined() + "</tr>"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        tableBody.children.map { visit($0) }.joined()
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        "<tr>" + tableRow.children.map { visit($0) }.joined() + "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        let tag = (tableCell.parent is Table.Head) ? "th" : "td"
        let inner = tableCell.children.map { visit($0) }.joined()
        return "<\(tag)>\(inner)</\(tag)>"
    }

    // MARK: - Escaping

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:  out.append(c)
            }
        }
        return out
    }

    static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
