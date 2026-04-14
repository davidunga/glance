import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

@main
struct GlanceApp: App {
    init() {
        // CLI mode: `glance --render file.md` prints rendered HTML and exits.
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--render" {
            guard let text = try? String(contentsOfFile: args[2], encoding: .utf8) else {
                FileHandle.standardError.write(Data("error: cannot read \(args[2])\n".utf8))
                exit(1)
            }
            print(MarkdownRenderer.render(text))
            exit(0)
        }

        // Allow new windows in the same group to merge as tabs.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    @AppStorage("theme") private var theme: Theme = .system
    @AppStorage("fontSize") private var fontSize: Double = FontSize.default
    @AppStorage("fontFamily") private var fontFamily: FontFamily = .sans

    var body: some Scene {
        // `for: UUID.self` lets `openWindow(value:)` spin up fresh window
        // instances. Combined with each window's `tabbingMode = .preferred`,
        // those new windows merge into the focused window as tabs.
        WindowGroup(for: UUID.self) { _ in
            ContentView(fontSize: fontSize,
                        fontFamily: fontFamily,
                        themeOverride: theme.colorScheme)
                .preferredColorScheme(theme.colorScheme)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            GlanceCommands(theme: $theme, fontSize: $fontSize, fontFamily: $fontFamily)
        }
    }
}

enum FontSize {
    static let `default`: Double = 16
    static let min: Double = 10
    static let max: Double = 32
    static let step: Double = 1
}

enum FontFamily: String, CaseIterable, Identifiable {
    case sans, serif, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sans:  return "Sans Serif"
        case .serif: return "Serif"
        case .mono:  return "Monospace"
        }
    }
    /// CSS font-family stack. Stays inside single-quoted JS / double-quoted
    /// HTML attributes — keep the inner quotes as plain double quotes only.
    var cssStack: String {
        switch self {
        case .sans:
            return #"-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif"#
        case .serif:
            return #""New York", "Charter", Georgia, "Times New Roman", serif"#
        case .mono:
            return #""SF Mono", ui-monospace, Menlo, "JetBrains Mono", monospace"#
        }
    }
}

// MARK: - Commands

struct GlanceCommands: Commands {
    @Binding var theme: Theme
    @Binding var fontSize: Double
    @Binding var fontFamily: FontFamily
    @FocusedValue(\.document) private var document
    @FocusedValue(\.findController) private var findController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { openWindow(value: UUID()) }
                .keyboardShortcut("t", modifiers: .command)

            Button("Open…") {
                if let doc = document {
                    doc.openPanel()
                } else if let url = MarkdownDocument.showOpenPanel() {
                    // No focused window — open a new one and pass it the URL
                    // via pendingURL, which ContentView picks up in onAppear.
                    MarkdownDocument.pendingURL = url
                    openWindow(value: UUID())
                }
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { findController?.show() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findController == nil)
            Button("Find Next") { findController?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(findController == nil)
            Button("Find Previous") { findController?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(findController == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                NotificationCenter.default.post(name: .glancePrint, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(document == nil)

            Button("Export as PDF…") {
                NotificationCenter.default.post(name: .glanceExportPDF, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(document == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Actual Size") { fontSize = FontSize.default }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") {
                fontSize = Swift.min(fontSize + FontSize.step, FontSize.max)
            }
            .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") {
                fontSize = Swift.max(fontSize - FontSize.step, FontSize.min)
            }
            .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button("Reload") { document?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(document == nil)

            Divider()

            Picker("Appearance", selection: $theme) {
                ForEach(Theme.allCases) { t in
                    Text(t.label).tag(t)
                }
            }

            Picker("Font", selection: $fontFamily) {
                ForEach(FontFamily.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
        }
    }
}

final class MarkdownDocument: ObservableObject {
    @Published var html: String
    @Published var title: String = "Glance"
    /// Directory containing the loaded markdown file. Used as the WKWebView
    /// baseURL so relative links (`./other.md`, `images/foo.png`, …) resolve
    /// against the file's location instead of the app bundle.
    @Published private(set) var baseURL: URL?

    private(set) var currentURL: URL?
    private var pollTimer: Timer?
    private var lastModified: Date?

    init() {
        self.html = MarkdownDocument.recentsWelcomeHTML()
    }

    /// Shows an NSOpenPanel and returns the selected URL, or nil if cancelled.
    /// Shared by instance `openPanel()` (loads into this window) and the
    /// no-window path in GlanceCommands (routes URL to a newly opened window).
    static func showOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let exts = ["md", "markdown", "mdown", "mkd", "mkdn", "txt", "csv", "tsv", "json"]
        let types = exts.compactMap { UTType(filenameExtension: $0) }
        // `.sourceCode` is the umbrella UTType for every code/script file the
        // system knows about, so it surfaces .py / .swift / .rs / etc. without
        // having to enumerate them by extension.
        panel.allowedContentTypes = types + [.plainText, .text, .sourceCode]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// URL to load when the next new window opens, set by CMD+O with no active window.
    static var pendingURL: URL?

    func openPanel() {
        if let url = MarkdownDocument.showOpenPanel() {
            load(url)
        }
    }

    func load(_ url: URL) {
        currentURL = url
        baseURL = url.deletingLastPathComponent()
        title = url.deletingPathExtension().lastPathComponent
        // macOS-managed recents list. Persists across launches and is the
        // same store the standard "Open Recent" submenu would read.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        reload()
        watch(url)
    }

    func openInEditor() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copySourceText() {
        guard let url = currentURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reload() {
        guard let url = currentURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if JsonRenderer.isJsonFile(url) {
            html = JsonRenderer.render(text)
        } else if CsvRenderer.isCsvFile(url) {
            html = CsvRenderer.render(text, url: url)
        } else if CodeRenderer.isCodeFile(url) {
            html = CodeRenderer.render(text, language: CodeRenderer.language(for: url))
        } else {
            html = MarkdownRenderer.render(text)
        }
    }

    private func watch(_ url: URL) {
        pollTimer?.invalidate()
        lastModified = modificationDate(of: url)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    private func checkForChanges() {
        guard let url = currentURL,
              let modified = modificationDate(of: url),
              modified != lastModified else { return }
        lastModified = modified
        reload()
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

extension MarkdownDocument {
    /// The landing page: a list of recent files. No tagline, no usage hints —
    /// just what the user might want to reopen. Items are anchors with
    /// `class="glance-open"` so the WebView's click bridge routes them to
    /// `document.load(url)` instead of opening externally via NSWorkspace.
    static func recentsWelcomeHTML() -> String {
        let recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        let listBody: String
        if recents.isEmpty {
            listBody = #"<div class="recents-empty">No recent files yet.</div>"#
        } else {
            let items = recents.map { url -> String in
                let name = htmlEscape(url.lastPathComponent)
                let path = htmlEscape(prettyPath(url))
                let href = htmlEscapeAttr(url.absoluteString)
                return #"""
                <a class="glance-open recent-item" href="\#(href)">
                    <div class="recent-name">\#(name)</div>
                    <div class="recent-path">\#(path)</div>
                </a>
                """#
            }.joined()
            listBody = #"<div class="recents-list">\#(items)</div>"#
        }

        return #"""
        <style>
        main {
            max-width: 560px !important;
            margin: 0 auto !important;
            padding: 72px 24px !important;
        }
        .open-hint {
            color: #8a8a8e;
            font-size: 0.72em;
            margin: 0 0 36px;
        }
        .open-hint kbd {
            font: 1em/1 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            background: rgba(128, 128, 128, 0.14);
            border: 1px solid rgba(128, 128, 128, 0.30);
            border-bottom-width: 2px;
            border-radius: 5px;
            padding: 1px 6px;
            color: inherit;
        }
        .recents-label {
            font-size: 0.72em;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: #8a8a8e;
            margin: 0 0 10px;
            padding-bottom: 8px;
            border-bottom: 1px solid rgba(128, 128, 128, 0.18);
        }
        .recents-empty {
            color: #8a8a8e;
            font-size: 0.92em;
            padding: 8px 0;
        }
        .recents-list {
            display: flex;
            flex-direction: column;
        }
        .recent-item {
            display: block;
            padding: 12px 14px;
            margin: 0 -14px;
            border-radius: 8px;
            text-decoration: none !important;
            color: inherit;
        }
        .recent-item:hover {
            background: rgba(128, 128, 128, 0.10);
        }
        .recent-name {
            font-size: 1.0em;
            font-weight: 500;
            margin-bottom: 2px;
        }
        .recent-path {
            font-size: 0.78em;
            color: #8a8a8e;
            font-family: "SF Mono", ui-monospace, Menlo, monospace;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        </style>
        <p class="open-hint">Press <kbd>⌘O</kbd> to open a file.</p>
        <div class="recents-label">Recents</div>
        \#(listBody)
        """#
    }

    private static func prettyPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
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

    private static func htmlEscapeAttr(_ s: String) -> String {
        htmlEscape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
