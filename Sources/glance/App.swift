import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum Theme: String, CaseIterable, Identifiable, Codable {
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

/// Content column width for the rendered page.
enum PageWidth: String, CaseIterable, Identifiable, Codable {
    case centered, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .centered: return "Centered"
        case .full:     return "Full Width"
        }
    }
    /// Value for the `--glance-page-width` CSS custom property, which the
    /// page stylesheet feeds to `main { max-width: … }`.
    var cssMaxWidth: String {
        switch self {
        case .centered: return "720px"
        case .full:     return "none"
        }
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate.application(_:open:)` when one or more file
    /// URLs arrive while the app is already running. Listening views drain
    /// `AppDelegate.pendingURLs` and spawn new document windows accordingly.
    static let glanceURLsQueued = Notification.Name("glance.urlsQueued")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// FIFO queue of file URLs waiting to be absorbed by a document window.
    /// Populated by `applicationWillFinishLaunching` (CLI args) and
    /// `application(_:open:)` (Finder / Apple Events). Drained by
    /// `ContentView.onAppear` and the `.glanceURLsQueued` notification
    /// handler. Main-queue-only — no locking needed.
    static var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true,  forKey: "ApplePersistenceIgnoreState")

        for arg in CommandLine.arguments.dropFirst() {
            guard !arg.hasPrefix("-") else { continue }
            let url = URL(fileURLWithPath: arg)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            AppDelegate.pendingURLs.append(url.standardizedFileURL)
        }
    }

    /// Cold-launch file open. Fires (via AppKit's default kAEOpenDocuments
    /// handler) BEFORE `applicationDidFinishLaunching`. The URL lands in
    /// `pendingURLs`, where the first window's `onAppear` picks it up; a
    /// window that finds nothing there simply stays empty.
    func application(_ application: NSApplication, open urls: [URL]) {
        let canonical = urls.map { $0.standardizedFileURL }
        AppDelegate.pendingURLs.append(contentsOf: canonical)
        NotificationCenter.default.post(name: .glanceURLsQueued, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Register warm-app kAEOpenDocuments handler. Cold-launch file opens
        // already went through AppKit's default handler (above), so we only
        // take over from here for subsequent opens.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    /// Warm-app kAEOpenDocuments handler (installed after first launch).
    @objc func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor,
                                        withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let listDesc = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return
        }
        var urls: [URL] = []
        let count = listDesc.numberOfItems
        guard count > 0 else { return }
        for i in 1...count {
            guard let itemDesc = listDesc.atIndex(i) else { continue }
            guard let urlDesc = itemDesc.coerce(toDescriptorType: DescType(typeFileURL)) else {
                continue
            }
            let data = urlDesc.data
            guard let urlStr = String(data: data, encoding: .utf8),
                  let url = URL(string: urlStr) else { continue }
            urls.append(url.standardizedFileURL)
        }
        guard !urls.isEmpty else { return }
        AppDelegate.pendingURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: .glanceURLsQueued, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Pops the next queued URL, or returns nil if the queue is empty.
    static func popPendingURL() -> URL? {
        pendingURLs.isEmpty ? nil : pendingURLs.removeFirst()
    }
}

@main
struct GlanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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

        // Each document gets its own standalone window — no tab merging.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @StateObject private var config = ConfigStore.shared

    var body: some Scene {
        // `for: UUID.self` lets `openWindow(value:)` spin up fresh,
        // fully-independent window instances — one document per window.
        WindowGroup(for: UUID.self) { _ in
            ContentView(fontSize: config.fontSize,
                        fontFamily: config.fontFamily,
                        pageWidth: config.pageWidth,
                        themeOverride: config.theme.colorScheme)
                .preferredColorScheme(config.theme.colorScheme)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            GlanceCommands(config: config)
        }
    }
}

enum FontSize {
    static let `default`: Double = 16
    static let min: Double = 10
    static let max: Double = 32
    static let step: Double = 1
}

enum FontFamily: String, CaseIterable, Identifiable, Codable {
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
    @ObservedObject var config: ConfigStore
    @FocusedValue(\.document) private var document
    @FocusedValue(\.findController) private var findController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            // Sits right below "About Glance" in the application menu.
            Button("Check for Updates…") { Updater.checkForUpdates() }
            Button("Reveal Config…") { config.revealInFinder() }
        }
        CommandGroup(replacing: .newItem) {
            // CMD+N opens an empty window; CMD+O picks a file and shows it in
            // the current window (focusing an existing window instead when
            // that file is already open somewhere).
            Button("New Window") {
                openWindow(value: UUID())
            }
                .keyboardShortcut("n", modifiers: .command)

            Button("Open…") {
                guard let url = MarkdownDocument.showOpenPanel() else { return }
                let canonical = url.standardizedFileURL
                // Uniqueness: if this file is already open somewhere, focus it.
                guard !WindowManager.shared.focusExistingWindow(for: canonical) else { return }
                if let doc = document {
                    doc.load(canonical)
                } else {
                    // No window at all — queue the URL and spin up a new one.
                    // The fresh window's onAppear pops the queue and loads it.
                    AppDelegate.pendingURLs.append(canonical)
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
            Button("Actual Size") { config.fontSize = FontSize.default }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") {
                config.fontSize = Swift.min(config.fontSize + FontSize.step, FontSize.max)
            }
            .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") {
                config.fontSize = Swift.max(config.fontSize - FontSize.step, FontSize.min)
            }
            .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button("Reload") { document?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(document == nil)

            Divider()

            Picker("Theme", selection: $config.theme) {
                ForEach(Theme.allCases) { t in
                    Text(t.label).tag(t)
                }
            }

            Picker("Font", selection: $config.fontFamily) {
                ForEach(FontFamily.allCases) { f in
                    Text(f.label).tag(f)
                }
            }

            Picker("Page Width", selection: $config.pageWidth) {
                ForEach(PageWidth.allCases) { w in
                    Text(w.label).tag(w)
                }
            }
        }
    }
}

// MARK: - WindowManager

/// Enforces one invariant: each open document appears in at most one window.
/// Opening a file that's already displayed focuses the existing window
/// instead of spawning a duplicate.
///
/// Tracks two maps:
///   - `windowToDoc`: which document lives in which window (populated by
///     `ContentView.WindowAccessor` via `register`).
///   - `urlToDoc`: which document currently displays which URL (populated by
///     `MarkdownDocument.load` via `updateURL`).
///
/// Entries are cleaned up on `willCloseNotification`.
final class WindowManager: ObservableObject {

    static let shared = WindowManager()

    private var registered  = Set<ObjectIdentifier>()
    // Canonical file URL → document currently showing that URL.
    private var urlToDoc    = [URL: MarkdownDocument]()
    // Window identity → document living in that window.
    private var windowToDoc = [ObjectIdentifier: MarkdownDocument]()

    private var observers: [Any] = []
    private var isClosingPlaceholders = false

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let w = note.object as? NSWindow else { return }
            self.windowWillClose(w)
        })
    }

    /// Wire a window and its document into the manager. Safe to call multiple
    /// times for the same window — only the first call does real work.
    func register(window: NSWindow, document: MarkdownDocument) {
        let id = ObjectIdentifier(window)
        windowToDoc[id] = document
        guard !registered.contains(id) else { return }
        registered.insert(id)

        // We never want these windows tabbed together.
        window.tabbingMode = .disallowed
        // Don't persist window state across launches — a fresh launch either
        // opens the files it was given or asks for one.
        window.isRestorable = false
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

    /// If `url` is already open in a window, bring that window to front and
    /// return `true`. Returns `false` when no matching window exists.
    @discardableResult
    func focusExistingWindow(for url: URL) -> Bool {
        let canonical = url.standardizedFileURL
        guard let doc = urlToDoc[canonical] else { return false }
        guard let win = window(for: doc) else { return false }
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

        // When the last visible window closes, also close any hidden placeholder
        // windows so applicationShouldTerminateAfterLastWindowClosed fires.
        guard !isClosingPlaceholders else { return }
        let hasVisible = NSApp.windows.contains { $0.isVisible }
        guard !hasVisible else { return }
        let placeholders = windowToDoc.compactMap { (wid, doc) -> NSWindow? in
            guard doc.currentURL == nil, doc.html.isEmpty else { return nil }
            return NSApp.windows.first { ObjectIdentifier($0) == wid }
        }
        guard !placeholders.isEmpty else { return }
        isClosingPlaceholders = true
        placeholders.forEach { $0.close() }
        isClosingPlaceholders = false
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
    /// When true the file's unrendered source text is shown instead of the
    /// rendered document. Per-window view mode, reset whenever a different
    /// file is loaded into this window.
    @Published private(set) var showRaw = false

    private(set) var currentURL: URL?
    private var pollTimer: Timer?
    private var lastModified: Date?

    /// Weak reference to the NSWindow hosting this document, set by
    /// `WindowAccessor` as soon as the view's NSView hierarchy has an
    /// attached window. Needed for the orphan-close path — `WindowManager`'s
    /// registration is deferred one run-loop hop, so a window spawned in
    /// response to kAEOpenDocuments might not be in the manager's tables yet
    /// when its onAppear decides to close itself. This pointer gives us a
    /// fallback handle we can close directly.
    weak var hostWindow: NSWindow?

    init() {
        self.html = ""
    }

    /// Window title format: `.../parent2/parent1/filename.ext`. Shows just
    /// enough path context to disambiguate files with the same name across
    /// different directories without consuming the entire title bar.
    private static func displayTitle(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3 else {
            return "/" + parts.joined(separator: "/")
        }
        return ".../" + parts.suffix(3).joined(separator: "/")
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

    func openPanel() {
        if let url = MarkdownDocument.showOpenPanel() {
            load(url)
        }
    }

    func load(_ url: URL) {
        // A new file starts in the normal rendered view, whatever the
        // previous document in this window was showing.
        if url != currentURL { showRaw = false }
        currentURL = url
        baseURL = url.deletingLastPathComponent()
        title = Self.displayTitle(for: url)
        // Keep the URL index in sync so WindowManager can find this window.
        WindowManager.shared.updateURL(url, for: self)
        reload()
        watch(url)
    }

    func openInEditor() {
        guard let url = currentURL else { return }
        if let editorApp = ConfigStore.shared.editorApp(for: url) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: editorApp,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Present an app picker and open the current file with the selected
    /// app. Triggered by the ⌥-alternate "Open with…" context-menu item.
    /// The picked app is persisted in the config as the editor for this
    /// file's extension, so subsequent "Open in Editor" uses it.
    func openInChooser() {
        guard let url = currentURL else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an app to open this file"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let ext = url.pathExtension
        if !ext.isEmpty {
            ConfigStore.shared.setEditor(appPath: app.path, forExtension: ext)
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func copyPath() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Flip between the rendered document and its raw source text.
    func toggleRaw() {
        guard currentURL != nil else { return }
        showRaw.toggle()
        reload()
    }

    func reload() {
        guard let url = currentURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if showRaw {
            html = RawRenderer.render(text)
        } else if JsonRenderer.isJsonFile(url) {
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
