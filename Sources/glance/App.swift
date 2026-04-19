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
    @ObservedObject private var windowManager = WindowManager.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // New Tab is only allowed in the main tab group — detached windows
            // are treated as tabs themselves, and "tabs inside tabs" isn't a
            // thing. The macOS system "Window › New Tab" item is a separate
            // channel; CMD+T is the one we fully control.
            Button("New Tab") { openWindow(value: UUID()) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!windowManager.keyWindowCanCreateTabs)

            Button("Open…") {
                guard let url = MarkdownDocument.showOpenPanel() else { return }
                let canonical = url.standardizedFileURL
                // Uniqueness: if this file is already open somewhere, focus it.
                guard !WindowManager.shared.focusExistingTab(for: canonical) else { return }
                if let doc = document {
                    doc.load(canonical)
                } else {
                    // No window at all — open a new one carrying the URL.
                    MarkdownDocument.pendingURL = canonical
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

// MARK: - Recent Documents

/// Persistent recent-file list backed by UserDefaults.standard.
///
/// Why not NSDocumentController.recentDocumentURLs?
/// The app uses ad-hoc signing ("-"), so the code signature changes on every
/// build. NSDocumentController stores recents in LSSharedFileList keyed to
/// the signature, meaning the list is silently wiped on every reinstall or
/// rebuild. UserDefaults.standard writes to the sandbox preferences plist
/// (~/Library/Containers/local.glance/…/local.glance.plist), which macOS
/// preserves across reinstalls as long as the bundle identifier is unchanged.
enum RecentDocuments {
    private static let key      = "recentDocumentPaths"
    private static let maxCount = 20

    /// Most-recently-opened URLs whose files still exist on disk.
    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Record `url` as the most-recently-opened file.
    static func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }          // keep the list duplicate-free
        paths.insert(path, at: 0)               // most-recent first
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
    }
}

// MARK: - WindowManager

/// Enforces three invariants for Glance's tabbed-window model:
///
/// 1. **Singleton tab group** — every window is a tab of one "main" NSWindow.
///    The first window created claims that role; all subsequent ones are added
///    via `addTabbedWindow` if they didn't auto-merge (via `tabbingIdentifier`).
///
/// 2. **Tab–document uniqueness** — opening a URL that is already displayed in
///    a tab focuses that tab instead of loading a duplicate.
///
/// 3. **No tabs-in-tabs** — CMD+T is disabled in windows that have been
///    detached from the main tab group, because those windows are themselves
///    conceptually tabs.
final class WindowManager: ObservableObject {

    static let shared = WindowManager()

    private(set) var mainWindow: NSWindow?

    // Tracks windows we have already processed so addTabbedWindow is called
    // at most once per NSWindow instance.
    private var registered  = Set<ObjectIdentifier>()
    // Canonical file URL → document currently showing that URL.
    private var urlToDoc    = [URL: MarkdownDocument]()
    // Window identity → document living in that window.
    private var windowToDoc = [ObjectIdentifier: MarkdownDocument]()

    /// Drives the CMD+T enabled state in GlanceCommands.
    @Published private(set) var keyWindowCanCreateTabs = true

    private var observers: [Any] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.keyWindowCanCreateTabs = self.isInMainGroup(w)
            self.applyTabbingPolicy(to: w)
        })
        // didMove fires throughout (and at the end of) a window-drag — which
        // is how a tab gets pulled out of a tab group. didBecomeKey is not
        // enough on its own: when the user grabs a tab, that tab is already
        // key, so detaching it never triggers another key-change notification.
        observers.append(nc.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.applyTabbingPolicy(to: w)
        })
        observers.append(nc.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.windowWillClose(w)
        })
    }

    // MARK: – Registration (called from ContentView's WindowAccessor)

    /// Wire a window and its document into the manager. Safe to call multiple
    /// times for the same window — only the first call does real work.
    func register(window: NSWindow, document: MarkdownDocument) {
        let id = ObjectIdentifier(window)
        windowToDoc[id] = document
        guard !registered.contains(id) else { return }
        registered.insert(id)

        // Make the window willing to participate in tabbing before we try to
        // join the main group — explicitly .preferred so auto-tabbing kicks
        // in regardless of the user's system preference.
        window.tabbingMode = .preferred

        if mainWindow == nil {
            // Very first window — it becomes the permanent main host.
            mainWindow = window
            keyWindowCanCreateTabs = true
        } else if !isInMainGroup(window) {
            // Window wasn't auto-grouped (e.g. opened while a detached window
            // was key) — slot it into the main group explicitly.
            mainWindow?.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        applyTabbingPolicy(to: window)
    }

    /// Update the URL↔document mapping when a document loads a new file (or
    /// clears its content). Call this from MarkdownDocument.load(_:).
    func updateURL(_ url: URL?, for document: MarkdownDocument) {
        // Drop any stale entry for this document first.
        urlToDoc = urlToDoc.filter { $0.value !== document }
        if let url {
            urlToDoc[url.standardizedFileURL] = document
        }
    }

    // MARK: – Queries

    /// True if `window` is the main window or one of its current tabs.
    func isInMainGroup(_ window: NSWindow) -> Bool {
        guard let main = mainWindow else { return true } // no main yet → anything goes
        if window === main { return true }
        return main.tabGroup?.windows.contains(window) ?? false
    }

    /// True if `window` exists outside the main tab group (i.e. the user
    /// dragged its tab out into a free-standing window).
    func isDetached(_ window: NSWindow) -> Bool {
        mainWindow != nil && !isInMainGroup(window)
    }

    // MARK: – Tabbing policy

    /// Detached windows are conceptually a single tab — no "+" button, no tab
    /// bar. Setting `tabbingMode = .disallowed` removes the "+" affordance and
    /// blocks accidental new-tab creation; toggling the tab bar off hides the
    /// strip for cases where the user had "Show Tab Bar" sticky from before
    /// the drag-out.
    ///
    /// The work is done both immediately and after a short delay because the
    /// drag-out animation can leave `tabGroup` / `isTabBarVisible` in flux for
    /// a frame or two before settling.
    func applyTabbingPolicy(to window: NSWindow) {
        enforceTabbingPolicy(on: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.enforceTabbingPolicy(on: window)
        }
    }

    private func enforceTabbingPolicy(on window: NSWindow) {
        if isInMainGroup(window) {
            window.tabbingMode = .preferred
            return
        }
        window.tabbingMode = .disallowed
        // Hide the tab strip whenever it's still visible on a detached window.
        // No `windows.count` gate: in our model a detached window is always a
        // singleton, and even if it isn't we'd rather strip the UI than leave
        // an inconsistent state.
        if let group = window.tabGroup, group.isTabBarVisible {
            window.toggleTabBar(nil)
        }
    }

    /// Move a detached window's tab back into the main tab group. Called from
    /// the WebView context menu's "Re-attach to Main Window" item.
    func reattach(_ window: NSWindow) {
        guard let main = mainWindow, window !== main, !isInMainGroup(window) else { return }
        // addTabbedWindow refuses windows whose tabbingMode is .disallowed, so
        // briefly flip back to .preferred for the move.
        window.tabbingMode = .preferred
        main.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// If `url` is already open in a tab, bring that tab to front and return
    /// `true`. Returns `false` when no matching tab exists.
    @discardableResult
    func focusExistingTab(for url: URL) -> Bool {
        let canonical = url.standardizedFileURL
        guard let doc = urlToDoc[canonical] else { return false }
        guard let win = window(for: doc) else { return false }
        if let group = win.tabGroup { group.selectedWindow = win }
        win.makeKeyAndOrderFront(nil)
        return true
    }

    /// Returns the NSWindow currently hosting `document`, if we know about it.
    func window(for document: MarkdownDocument) -> NSWindow? {
        guard let wid = windowToDoc.first(where: { $0.value === document })?.key
        else { return nil }
        return NSApp.windows.first(where: { ObjectIdentifier($0) == wid })
    }

    // MARK: – Private

    private func windowWillClose(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let doc = windowToDoc.removeValue(forKey: id) {
            urlToDoc = urlToDoc.filter { $0.value !== doc }
        }
        registered.remove(id)
        if window === mainWindow {
            // Promote a surviving tab so future windows still merge into the
            // group. Without this, closing the original main tab leaves
            // mainWindow == nil and the next opened window starts a new group.
            mainWindow = window.tabGroup?.windows.first(where: { $0 !== window })
        }
    }
}

// MARK: - Document

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
        RecentDocuments.add(url)
        // Keep the URL index in sync so WindowManager can find this tab.
        WindowManager.shared.updateURL(url, for: self)
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
        let recents = RecentDocuments.urls

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
