import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let glanceExportPDF = Notification.Name("glance.exportPDF")
    static let glancePrint     = Notification.Name("glance.print")
    static let glanceReload    = Notification.Name("glance.reload")
    static let glanceCopyText  = Notification.Name("glance.copyText")
    static let glanceOpenInEditor = Notification.Name("glance.openInEditor")
}

/// WKWebView subclass that mirrors its window's `effectiveAppearance` when
/// it has no explicit forced appearance. SwiftUI's wrapper NSView caches its
/// own appearance and won't reliably forward window-level changes, so simply
/// setting `webView.appearance = nil` and hoping inheritance works leaves the
/// content stale until something else triggers a relayout. Observing the
/// window directly fixes that.
final class GlanceWebView: WKWebView {
    /// `.aqua` / `.darkAqua` to pin the appearance, `nil` to follow the
    /// hosting window's `effectiveAppearance` automatically.
    var forcedAppearance: NSAppearance.Name? {
        didSet { applyAppearance() }
    }

    private var windowAppearanceObservation: NSKeyValueObservation?

    /// WKWebView's internals call `registerForDraggedTypes` repeatedly (on
    /// init, after viewDidMoveToWindow, after page loads, …). A one-shot
    /// `unregisterDraggedTypes()` call gets clobbered the next time WebKit
    /// re-registers. Overriding the entry point to a no-op guarantees this
    /// view never accepts drags, so file drops fall through to SwiftUI's
    /// `.onDrop` handler on the host view.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // intentionally empty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowAppearanceObservation?.invalidate()
        windowAppearanceObservation = window?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.applyAppearance()
        }
        applyAppearance()
    }

    // MARK: - Context menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()

        menu.addItem(withTitle: "Copy Document Text",
                     action: #selector(copyDocumentText), keyEquivalent: "")

        menu.addItem(.separator())

        let currentFont = UserDefaults.standard.string(forKey: "fontFamily") ?? "sans"
        for (label, key) in [("Sans Serif", "sans"), ("Serif", "serif"), ("Monospace", "mono")] {
            let item = NSMenuItem(title: label, action: #selector(setFont(_:)), keyEquivalent: "")
            item.representedObject = key
            item.state = key == currentFont ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let currentTheme = UserDefaults.standard.string(forKey: "theme") ?? "system"
        for (label, key) in [("Dark", "dark"), ("Light", "light"), ("System", "system")] {
            let item = NSMenuItem(title: label, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.representedObject = key
            item.state = key == currentTheme ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        menu.addItem(withTitle: "Open in Editor",
                     action: #selector(openInEditor), keyEquivalent: "")

        menu.addItem(withTitle: "Reload",
                     action: #selector(reloadDocument), keyEquivalent: "")
    }

    @objc private func copyDocumentText() {
        NotificationCenter.default.post(name: .glanceCopyText, object: nil)
    }

    @objc private func setFont(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "fontFamily")
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "theme")
    }

    @objc private func openInEditor() {
        NotificationCenter.default.post(name: .glanceOpenInEditor, object: nil)
    }

    @objc private func reloadDocument() {
        NotificationCenter.default.post(name: .glanceReload, object: nil)
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let name: NSAppearance.Name
        if let forced = forcedAppearance {
            name = forced
        } else if let windowAppearance = window?.effectiveAppearance,
                  let best = windowAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            name = best
        } else {
            name = .aqua
        }
        if appearance?.name != name {
            appearance = NSAppearance(named: name)
        }
    }
}

struct WebView: NSViewRepresentable {
    let html: String
    /// Directory the markdown file lives in, so relative links and images
    /// resolve against the user's filesystem instead of the app bundle.
    let baseURL: URL?
    let fileURL: URL?
    let fontSize: Double
    let fontFamily: FontFamily
    /// `nil` for the System theme. When non-nil we pin WKWebView's appearance
    /// so `prefers-color-scheme` resolves to the user's choice. When nil the
    /// view tracks its window's `effectiveAppearance` via KVO (see
    /// `GlanceWebView`), so OS / in-app theme changes propagate live.
    let themeOverride: ColorScheme?
    let findController: FindController
    /// Called when the user clicks an `<a class="glance-open">` link in the
    /// rendered page (e.g. an item on the recents landing page). Lets the
    /// caller load the URL into the *current* document instead of farming it
    /// out to NSWorkspace.
    let onOpenInWindow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GlanceWebView {
        let config = WKWebViewConfiguration()

        // JavaScript click bridge: WebKit blocks file:// navigation outside
        // the sandbox at the WebPageProxy level, *before* the navigation
        // delegate runs — `decidePolicyFor` never sees the click. We work
        // around this by injecting a click listener that calls
        // `e.preventDefault()` and posts the resolved href back to native
        // through a script message handler.
        //
        // Two routes:
        //   - `glanceLink`: external open via NSWorkspace (LaunchServices,
        //     bypasses our sandbox).
        //   - `glanceOpen`: load the URL into the current document. Used for
        //     `<a class="glance-open">` links such as the recents list on the
        //     landing page.
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.linkBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.openInWindowName)
        let bridgeScript = WKUserScript(
            source: Self.linkBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(bridgeScript)
        config.userContentController = userContentController
        config.setURLSchemeHandler(GlanceFileSchemeHandler(), forURLScheme: "glance-file")

        let view = GlanceWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.onOpenInWindow = onOpenInWindow
        context.coordinator.bind(findController: findController)
        context.coordinator.installNotificationHandlers()
        return view
    }

    func updateNSView(_ webView: GlanceWebView, context: Context) {
        // Re-bind in case SwiftUI handed us a different controller instance.
        context.coordinator.bind(findController: findController)
        context.coordinator.onOpenInWindow = onOpenInWindow

        // Theme: Light/Dark pin the appearance, System (nil) lets GlanceWebView
        // mirror its window's effectiveAppearance via KVO.
        switch themeOverride {
        case .light: webView.forcedAppearance = .aqua
        case .dark:  webView.forcedAppearance = .darkAqua
        case .none:  webView.forcedAppearance = nil
        @unknown default: webView.forcedAppearance = nil
        }

        // Font size and font family live in CSS custom properties, so when
        // only those change we can patch them on the existing page via JS —
        // no full reload, no scroll jump. We still do a full load whenever
        // the rendered markup itself changed.
        if context.coordinator.lastHTML == html {
            if context.coordinator.lastFontSize != fontSize {
                context.coordinator.lastFontSize = fontSize
                let js = "document.documentElement.style.setProperty('--glance-font-size', '\(Int(fontSize))px');"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            if context.coordinator.lastFontFamily != fontFamily {
                context.coordinator.lastFontFamily = fontFamily
                let js = "document.documentElement.style.setProperty('--glance-font-family', '\(fontFamily.cssStack)');"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            return
        }
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastFontFamily = fontFamily
        context.coordinator.currentFilePath = fileURL?.path
        let resolved = resolveLocalPaths(html, base: baseURL)
        context.coordinator.lastHTML = html
        webView.loadHTMLString(wrap(resolved), baseURL: baseURL ?? Bundle.main.resourceURL)
    }

    /// Click interceptor injected on every page load. Captures clicks during
    /// the capture phase so it runs before WebKit's own navigation, calls
    /// `preventDefault()`, and posts the link's resolved `href` (already
    /// absolute thanks to the document baseURI) to the native bridge.
    /// Same-page anchors are left for WebKit so headings still scroll.
    private static let linkBridgeJS = """
    document.addEventListener('click', function(e) {
        var link = e.target.closest('a');
        if (!link) return;
        var raw = link.getAttribute('href');
        if (!raw) return;
        if (raw.charAt(0) === '#') return;
        var resolved = link.href;
        if (!resolved) return;
        e.preventDefault();
        try {
            if (link.classList.contains('glance-open')) {
                window.webkit.messageHandlers.glanceOpen.postMessage(resolved);
            } else {
                window.webkit.messageHandlers.glanceLink.postMessage(resolved);
            }
        } catch (err) {}
    }, true);
    """

    /// Rewrites relative `<img src="…">` paths to use the custom
    /// `glance-file://` scheme so WKWebView can load local images.
    private func resolveLocalPaths(_ html: String, base: URL?) -> String {
        guard let base = base else { return html }
        let pattern = #"(<img\s[^>]*?src\s*=\s*")([^"]+)(")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

        var result = ""
        var cursor = html.startIndex

        regex.enumerateMatches(in: html, range: NSRange(html.startIndex..., in: html)) { match, _, _ in
            guard let match = match,
                  let fullRange = Range(match.range, in: html),
                  let prefixRange = Range(match.range(at: 1), in: html),
                  let srcRange = Range(match.range(at: 2), in: html),
                  let suffixRange = Range(match.range(at: 3), in: html) else { return }

            let src = String(html[srcRange])
            guard !src.hasPrefix("http://"), !src.hasPrefix("https://"),
                  !src.hasPrefix("data:"), !src.hasPrefix("glance-file://") else { return }

            let absolutePath = src.hasPrefix("/") ? src : base.appendingPathComponent(src).path

            result += html[cursor..<fullRange.lowerBound]
            result += html[prefixRange]
            result += "glance-file://" + absolutePath
            result += html[suffixRange]
            cursor = fullRange.upperBound
        }

        result += html[cursor...]
        return result
    }

    private func wrap(_ body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            --glance-font-size: \(Int(fontSize))px;
            --glance-font-family: \(fontFamily.cssStack);
        }
        \(Self.css)
        \(Self.hljsLightCSS)
        @media (prefers-color-scheme: dark) {
        \(Self.hljsDarkCSS)
        }
        </style>
        </head>
        <body><main>\(body)</main>
        <script>\(Self.hljsJS)</script>
        <script>if (window.hljs) { hljs.highlightAll(); }</script>
        </body>
        </html>
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let linkBridgeName = "glanceLink"
        static let openInWindowName = "glanceOpen"

        weak var webView: WKWebView?
        var lastHTML: String?
        var lastFontSize: Double?
        var lastFontFamily: FontFamily?
        var onOpenInWindow: ((URL) -> Void)?
        private weak var findController: FindController?
        private var observers: [NSObjectProtocol] = []
        var currentFilePath: String?
        private var scrollTimer: Timer?
        private let scrollKey = "scrollPositions"

        // MARK: - JS link bridge

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let urlString = message.body as? String,
                  let url = URL(string: urlString) else { return }
            switch message.name {
            case Self.linkBridgeName:
                // External link → user's default app via LaunchServices.
                NSWorkspace.shared.open(url)
            case Self.openInWindowName:
                // Internal link (e.g. recents list) → load into the focused
                // document. Hop to main: WKScriptMessageHandler can be called
                // off-main and document.load mutates @Published state.
                DispatchQueue.main.async { [weak self] in
                    self?.onOpenInWindow?(url)
                }
            default:
                break
            }
        }

        func bind(findController: FindController) {
            guard self.findController !== findController else { return }
            self.findController = findController
            findController.attach { [weak self] query, backwards in
                self?.runFind(query, backwards: backwards)
            }
        }

        private func runFind(_ query: String, backwards: Bool) {
            guard let webView = webView, !query.isEmpty else {
                findController?.matchFound = true
                return
            }
            let config = WKFindConfiguration()
            config.backwards = backwards
            config.caseSensitive = false
            config.wraps = true
            webView.find(query, configuration: config) { [weak self] result in
                self?.findController?.matchFound = result.matchFound
            }
        }

        func installNotificationHandlers() {
            guard observers.isEmpty else { return }
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .glanceExportPDF, object: nil, queue: .main) { [weak self] _ in
                self?.exportPDF()
            })
            observers.append(nc.addObserver(forName: .glancePrint, object: nil, queue: .main) { [weak self] _ in
                self?.printDocument()
            })

            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, let path = self.currentFilePath else { return }
                self.webView?.evaluateJavaScript("window.scrollY") { result, _ in
                    guard let y = result as? CGFloat, y > 0 else { return }
                    var positions = UserDefaults.standard.dictionary(forKey: self.scrollKey) as? [String: Double] ?? [:]
                    positions[path] = Double(y)
                    UserDefaults.standard.set(positions, forKey: self.scrollKey)
                }
            }
        }

        deinit {
            scrollTimer?.invalidate()
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Same-page anchors (e.g. `[TOC](#section)`) — let WebKit scroll
            // to the fragment instead of trying to open a new file/URL.
            if url.fragment != nil,
               let docURL = webView.url,
               stripFragment(url) == stripFragment(docURL) {
                decisionHandler(.allow)
                return
            }
            // Everything else — file://, http(s)://, mailto: — gets handed
            // to LaunchServices, which opens the URL in the user's default
            // app. Sandboxed: NSWorkspace.open is allowed for any URL.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let path = currentFilePath,
                  let positions = UserDefaults.standard.dictionary(forKey: scrollKey) as? [String: Double],
                  let y = positions[path], y > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
        }

        private func stripFragment(_ url: URL) -> URL? {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url
        }

        // MARK: PDF export

        private func exportPDF() {
            guard let webView = webView else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            let suggested = (webView.window?.title.isEmpty == false ? webView.window!.title : "Document")
            panel.nameFieldStringValue = "\(suggested).pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let cfg = WKPDFConfiguration()
            webView.createPDF(configuration: cfg) { result in
                switch result {
                case .success(let data):
                    do { try data.write(to: url) }
                    catch { NSAlert(error: error).runModal() }
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
            }
        }

        // MARK: Print

        private func printDocument() {
            guard let webView = webView, let window = webView.window else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 36
            info.rightMargin = 36
            let op = webView.printOperation(with: info)
            op.view?.frame = webView.bounds
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }

    // MARK: - Bundled assets

    static let hljsJS:       String = loadResource("highlight.min",      "js")
    static let hljsLightCSS: String = loadResource("atom-one-light.min", "css")
    static let hljsDarkCSS:  String = loadResource("atom-one-dark.min",  "css")

    private static func loadResource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return content
    }

    // MARK: - Page CSS

    static let css = """
    :root { color-scheme: light dark; }
    html, body {
        margin: 0;
        padding: 0;
        -webkit-font-smoothing: antialiased;
    }
    body {
        font: var(--glance-font-size, 16px)/1.65 var(--glance-font-family, -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif);
        color: #1d1d1f;
        background: #ffffff;
    }
    main {
        max-width: 720px;
        margin: 56px auto 96px;
        padding: 0 32px;
    }
    h1, h2, h3, h4, h5, h6 {
        font-family: var(--glance-font-family, -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif);
        font-weight: 600;
        line-height: 1.2;
        margin: 1.6em 0 0.5em;
        letter-spacing: -0.011em;
    }
    h1 { font-size: 2.1em; letter-spacing: -0.022em; margin-top: 0.2em; }
    h2 { font-size: 1.55em; }
    h3 { font-size: 1.25em; }
    h4 { font-size: 1.05em; }
    p  { margin: 0 0 1em; }
    a  { color: #0066cc; text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { font-weight: 600; }
    em { font-style: italic; }
    code {
        font: 0.88em/1.5 "SF Mono", ui-monospace, Menlo, monospace;
        background: rgba(0,0,0,0.055);
        padding: 0.15em 0.4em;
        border-radius: 5px;
    }
    pre {
        background: rgba(0,0,0,0.045);
        padding: 16px 20px;
        border-radius: 10px;
        overflow-x: auto;
        line-height: 1.55;
        margin: 1.2em 0;
    }
    pre code { background: none; padding: 0; font-size: 0.86em; }
    /* Let highlight.js token colors apply but keep our pre background. */
    pre code.hljs {
        background: transparent !important;
        padding: 0 !important;
        display: inline !important;
        overflow: visible !important;
        color: inherit;
    }
    blockquote {
        margin: 1.2em 0;
        padding: 0.2em 0 0.2em 1.1em;
        border-left: 3px solid #d2d2d7;
        color: #6e6e73;
    }
    blockquote p:last-child { margin-bottom: 0; }
    hr {
        border: none;
        border-top: 1px solid rgba(0,0,0,0.1);
        margin: 2.2em 0;
    }
    ul, ol { padding-left: 1.6em; margin: 0 0 1em; }
    li { margin: 0.2em 0; }
    li > p { margin: 0.2em 0; }
    li.task { list-style: none; margin-left: -1.4em; }
    li.task input { margin-right: 0.5em; }
    table {
        border-collapse: collapse;
        margin: 1.2em 0;
        font-size: 0.95em;
    }
    th, td {
        padding: 8px 14px;
        border: 1px solid rgba(128,128,128,0.28);
        text-align: left;
    }
    th { background: rgba(128,128,128,0.08); font-weight: 600; }
    img { max-width: 100%; border-radius: 8px; }
    kbd {
        font: 0.85em/1 "SF Mono", ui-monospace, Menlo, monospace;
        padding: 2px 6px;
        border: 1px solid rgba(128,128,128,0.35);
        border-bottom-width: 2px;
        border-radius: 5px;
        background: rgba(128,128,128,0.08);
    }
    @media (prefers-color-scheme: dark) {
        body { color: #f5f5f7; background: #1e1e1e; }
        a { color: #6cb4ff; }
        code { background: rgba(255,255,255,0.085); }
        pre  { background: rgba(255,255,255,0.06); }
        blockquote { border-color: #444; color: #a1a1a6; }
        hr   { border-color: rgba(255,255,255,0.12); }
        th   { background: rgba(255,255,255,0.06); }
        th, td { border-color: rgba(255,255,255,0.14); }
        kbd { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.2); }
    }
    """
}

// MARK: - Local-file scheme handler

/// Serves local files to WKWebView via the `glance-file://` scheme.
/// `loadHTMLString` doesn't grant the web process file-read access, so
/// relative `<img src>` paths are rewritten to use this scheme instead.
final class GlanceFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        guard let data = FileManager.default.contents(atPath: path) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(url: url, mimeType: mime,
                                   expectedContentLength: data.count,
                                   textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
