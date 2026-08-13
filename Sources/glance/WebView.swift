import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by the File menu. Every web view hears it, so each one checks
    /// whether it is in the key window before acting.
    static let glanceExportPDF = Notification.Name("glance.exportPDF")
    static let glancePrint     = Notification.Name("glance.print")
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

    /// The document shown in this web view's window.
    ///
    /// Context-menu commands used to go out as app-wide notifications, which
    /// meant every open window acted on them at once — toggling raw view in
    /// one window toggled it everywhere, and "Copy Path" copied whichever
    /// window answered last. Reaching the document directly keeps each menu
    /// where it was opened.
    private var document: MarkdownDocument? {
        guard let window else { return nil }
        return WindowManager.shared.document(for: window)
    }

    private var windowAppearanceObservation: NSKeyValueObservation?
    private weak var observedWindow: NSWindow?

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
        observeWindowAppearance()
        applyAppearance()
    }

    /// Point the appearance observation at the window this view is actually
    /// in. Called from `viewDidMoveToWindow` *and* from every `updateNSView`,
    /// because AppKit hands this view a different window than it started with
    /// — SwiftUI swaps windows during launch — and a view that happened to be
    /// window-less the last time this ran would otherwise never track
    /// appearance again, leaving the page stuck in the scheme it first
    /// rendered while every other window follows along.
    func observeWindowAppearance() {
        guard observedWindow !== window else { return }
        windowAppearanceObservation?.invalidate()
        observedWindow = window
        windowAppearanceObservation = window?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.applyAppearance()
        }
    }

    // MARK: - Context menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()

        // Keep-on-top toggle. Reflects the current window level with a
        // checkmark; the action flips it.
        let keepOnTop = NSMenuItem(title: "Keep on Top",
                                   action: #selector(toggleKeepOnTop),
                                   keyEquivalent: "")
        keepOnTop.state = (window?.level == .floating) ? .on : .off
        menu.addItem(keepOnTop)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Copy Path",
                     action: #selector(copyPath), keyEquivalent: "")

        menu.addItem(withTitle: "Reveal in Finder",
                     action: #selector(revealInFinder), keyEquivalent: "")

        menu.addItem(withTitle: "Open in Editor",
                     action: #selector(openInEditor), keyEquivalent: "")

        // Alternate: appears in place of "Open in Editor" while ⌥ is held,
        // letting the user pick a different app to open the file with.
        let openInOther = NSMenuItem(title: "Open with…",
                                      action: #selector(openInChooser),
                                      keyEquivalent: "")
        openInOther.keyEquivalentModifierMask = .option
        openInOther.isAlternate = true
        menu.addItem(openInOther)

        menu.addItem(.separator())

        // Toggles between the rendered document and its unmodified source
        // text; the checkmark reflects which one is on screen.
        let showRaw = NSMenuItem(title: "Show as Raw",
                                 action: #selector(toggleRaw),
                                 keyEquivalent: "")
        showRaw.state = (document?.showRaw ?? false) ? .on : .off
        menu.addItem(showRaw)
    }

    @objc private func toggleRaw()      { document?.toggleRaw() }
    @objc private func copyPath()       { document?.copyPath() }
    @objc private func revealInFinder() { document?.revealInFinder() }
    @objc private func openInEditor()   { document?.openInEditor() }
    @objc private func openInChooser()  { document?.openInChooser() }

    @objc private func toggleKeepOnTop() {
        guard let window else { return }
        // `.floating` pins the window above regular app windows; `.normal` is
        // the default. We flip between just these two — other levels
        // (statusBar, modalPanel, …) would change stacking behavior in ways
        // users wouldn't expect from a "keep on top" toggle.
        window.level = (window.level == .floating) ? .normal : .floating
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let name: NSAppearance.Name
        if let forced = forcedAppearance {
            name = forced
        } else {
            // No window yet (mid-launch, or between window swaps): fall back
            // to the app's own appearance rather than assuming light, which
            // would render a dark-mode document on a white page.
            let source = window?.effectiveAppearance ?? NSApp.effectiveAppearance
            name = source.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
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
    /// Content column width — centered reading column or edge-to-edge.
    let pageWidth: PageWidth
    /// `nil` for the System theme. When non-nil we pin WKWebView's appearance
    /// so `prefers-color-scheme` resolves to the user's choice. When nil the
    /// view tracks its window's `effectiveAppearance` via KVO (see
    /// `GlanceWebView`), so OS / in-app theme changes propagate live.
    let themeOverride: ColorScheme?
    let findController: FindController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GlanceWebView {
        let config = WKWebViewConfiguration()

        // JavaScript click bridge: WebKit blocks file:// navigation outside
        // the sandbox at the WebPageProxy level, *before* the navigation
        // delegate runs — `decidePolicyFor` never sees the click. We work
        // around this by injecting a click listener that calls
        // `e.preventDefault()` and posts the resolved href back to native
        // through the `glanceLink` script message handler, which opens it
        // via NSWorkspace (LaunchServices, bypasses our sandbox).
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.linkBridgeName)
        userContentController.add(context.coordinator, name: Coordinator.copyBridgeName)
        for source in [Self.linkBridgeJS, Self.codeCopyJS] {
            userContentController.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        config.userContentController = userContentController
        config.setURLSchemeHandler(GlanceFileSchemeHandler(), forURLScheme: "glance-file")

        let view = GlanceWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.bind(findController: findController)
        context.coordinator.installNotificationHandlers()
        return view
    }

    func updateNSView(_ webView: GlanceWebView, context: Context) {
        // Re-bind in case SwiftUI handed us a different controller instance.
        context.coordinator.bind(findController: findController)
        webView.observeWindowAppearance()

        // Theme: Light/Dark pin the appearance, System (nil) lets GlanceWebView
        // mirror its window's effectiveAppearance via KVO.
        switch themeOverride {
        case .light: webView.forcedAppearance = .aqua
        case .dark:  webView.forcedAppearance = .darkAqua
        case .none:  webView.forcedAppearance = nil
        @unknown default: webView.forcedAppearance = nil
        }

        // Font size, font family and page width live in CSS custom
        // properties, so when only those change we can patch them on the
        // existing page via JS — no full reload, no scroll jump. We still do
        // a full load whenever the rendered markup itself changed.
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
            if context.coordinator.lastPageWidth != pageWidth {
                context.coordinator.lastPageWidth = pageWidth
                let js = "document.documentElement.style.setProperty('--glance-page-width', '\(pageWidth.cssMaxWidth)');"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            return
        }
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastFontFamily = fontFamily
        context.coordinator.lastPageWidth = pageWidth
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
        e.preventDefault();
        try {
            var resolved = link.href;
            if (!resolved) return;
            window.webkit.messageHandlers.glanceLink.postMessage(resolved);
        } catch (err) {}
    }, true);
    """

    /// Adds an icon-only copy button to every code block. Runs after the page
    /// is parsed, so it also covers the single big block that whole-file views
    /// (source, JSON, raw) render.
    private static let codeCopyJS = """
    (function () {
        var COPY = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5 A1.5 1.5 0 0 0 9 2.5 H4 A1.5 1.5 0 0 0 2.5 4 v5 a1.5 1.5 0 0 0 1 1"/></svg>';
        var DONE = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8.5 6.2 11.7 13 5"/></svg>';
        document.querySelectorAll('pre').forEach(function (pre) {
            if (pre.querySelector('.glance-copy')) return;
            var button = document.createElement('button');
            button.className = 'glance-copy';
            button.type = 'button';
            button.title = 'Copy';
            button.setAttribute('aria-label', 'Copy code');
            button.innerHTML = COPY;
            button.addEventListener('click', function (event) {
                event.preventDefault();
                event.stopPropagation();
                var code = pre.querySelector('code');
                var text = (code || pre).innerText;
                try {
                    window.webkit.messageHandlers.glanceCopy.postMessage(text);
                } catch (err) { return; }
                button.innerHTML = DONE;
                button.classList.add('copied');
                setTimeout(function () {
                    button.innerHTML = COPY;
                    button.classList.remove('copied');
                }, 1200);
            });
            pre.appendChild(button);
        });
    })();
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
            --glance-page-width: \(pageWidth.cssMaxWidth);
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
        static let copyBridgeName = "glanceCopy"

        weak var webView: WKWebView?
        var lastHTML: String?
        var lastFontSize: Double?
        var lastFontFamily: FontFamily?
        var lastPageWidth: PageWidth?
        private weak var findController: FindController?
        private var observers: [NSObjectProtocol] = []
        var currentFilePath: String?
        private var scrollTimer: Timer?
        private let scrollKey = "scrollPositions"

        // MARK: - JS link bridge

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            switch message.name {
            case Self.copyBridgeName:
                // A code block's copy button. The page can't reach the
                // pasteboard itself, so it hands the text over here.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
            case Self.linkBridgeName:
                // Link click → user's default app via LaunchServices.
                guard let url = URL(string: body) else { return }
                NSWorkspace.shared.open(url)
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
            // Both notifications reach every window's coordinator; only the
            // focused one should put up a dialog.
            observers.append(nc.addObserver(forName: .glanceExportPDF, object: nil, queue: .main) { [weak self] _ in
                guard self?.webView?.window?.isKeyWindow == true else { return }
                self?.exportPDF()
            })
            observers.append(nc.addObserver(forName: .glancePrint, object: nil, queue: .main) { [weak self] _ in
                guard self?.webView?.window?.isKeyWindow == true else { return }
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
        max-width: var(--glance-page-width, 720px);
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
        position: relative;
        background: rgba(0,0,0,0.045);
        padding: 16px 20px;
        border-radius: 10px;
        overflow-x: auto;
        line-height: 1.55;
        margin: 1.2em 0;
    }
    /* One point smaller than the document text, so code sits quieter than
       prose without going small enough to squint at. */
    pre code {
        background: none;
        padding: 0;
        font-size: calc(var(--glance-font-size, 16px) - 1px);
    }
    .glance-copy {
        position: absolute;
        top: 8px;
        right: 8px;
        width: 26px;
        height: 26px;
        padding: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border: 1px solid rgba(128,128,128,0.28);
        border-radius: 6px;
        background: rgba(128,128,128,0.12);
        color: #55555a;
        cursor: pointer;
        opacity: 0;
        transition: opacity 0.12s ease, background 0.12s ease;
    }
    pre:hover > .glance-copy, .glance-copy:focus-visible { opacity: 1; }
    .glance-copy:hover { background: rgba(128,128,128,0.24); }
    .glance-copy.copied { opacity: 1; color: #1a8a3f; }
    .glance-copy svg { width: 14px; height: 14px; display: block; }
    @media print { .glance-copy { display: none; } }
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
        .glance-copy { color: #b0b0b5; border-color: rgba(255,255,255,0.18); background: rgba(255,255,255,0.08); }
        .glance-copy:hover { background: rgba(255,255,255,0.16); }
        .glance-copy.copied { color: #4fd07a; }
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
