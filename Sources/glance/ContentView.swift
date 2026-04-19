import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    let fontSize: Double
    let fontFamily: FontFamily
    /// `nil` means the user picked the "System" theme. Forwarded to the
    /// WebView so it can drop its explicit `appearance` and inherit from the
    /// window — that way OS / window appearance changes propagate live.
    let themeOverride: ColorScheme?

    // Each window owns its own document. Sharing one @StateObject at the App
    // level means every window in the WindowGroup renders the same content.
    @StateObject private var document = MarkdownDocument()
    @StateObject private var find = FindController()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(html: document.html,
                    baseURL: document.baseURL,
                    fileURL: document.currentURL,
                    fontSize: fontSize,
                    fontFamily: fontFamily,
                    themeOverride: themeOverride,
                    findController: find,
                    onOpenInWindow: { url in
                        // In-page link click (glance-open anchor, e.g. a
                        // recents-list item). If the file is already open in
                        // another window, focus it and close this welcome
                        // window — mirrors the "load replaces welcome" path
                        // so the user doesn't end up with a redundant
                        // welcome window.
                        DispatchQueue.main.async {
                            let canonical = url.standardizedFileURL
                            if WindowManager.shared.focusExistingWindow(for: canonical) {
                                closeIfEmpty()
                            } else {
                                document.load(canonical)
                            }
                        }
                    })
                .frame(minWidth: 640, minHeight: 480)

            if find.isVisible {
                FindBar(controller: find)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: find.isVisible)
        .navigationTitle(document.title)
        .focusedSceneValue(\.document, document)
        .focusedSceneValue(\.findController, find)
        .background(WindowAccessor { window in
            // Register with WindowManager. Idempotent — safe to call on every
            // SwiftUI update; only the first call per window does real work.
            // The manager pins tabbingMode = .disallowed and isRestorable =
            // false so each window stays standalone and fresh launches don't
            // resurrect the previous session.
            WindowManager.shared.register(window: window, document: document)
        })
        .onAppear {
            // Consume a URL queued by CMD+O when no window was active.
            // Also apply the uniqueness check: if the pending URL is already
            // open in another window, focus that window and discard this
            // freshly created host (it was opened solely to carry the URL).
            if let url = MarkdownDocument.pendingURL {
                MarkdownDocument.pendingURL = nil
                DispatchQueue.main.async {
                    if WindowManager.shared.focusExistingWindow(for: url.standardizedFileURL) {
                        closeIfEmpty()
                    } else {
                        document.load(url)
                    }
                }
            }
        }
        .onOpenURL { url in
            // Defer to next runloop tick: synchronously mutating @Published
            // state during initial scene setup races with SwiftUI's layout
            // engine and triggers a RenderBox precondition failure.
            //
            // SwiftUI's typed WindowGroup auto-creates a fresh window when an
            // external URL arrives, then routes the URL here. If the URL is
            // already open in another window we focus that window AND close
            // this newly-created empty host so the user doesn't end up with
            // an orphan welcome page next to their document.
            DispatchQueue.main.async {
                let canonical = url.standardizedFileURL
                if WindowManager.shared.focusExistingWindow(for: canonical) {
                    closeIfEmpty()
                } else {
                    document.load(canonical)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    DispatchQueue.main.async {
                        let canonical = url.standardizedFileURL
                        // Drop happened on this window deliberately — keep it
                        // around even if the file is already shown elsewhere.
                        if !WindowManager.shared.focusExistingWindow(for: canonical) {
                            document.load(canonical)
                        }
                    }
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .glanceReload)) { _ in
            document.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .glanceCopyText)) { _ in
            document.copySourceText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .glanceOpenInEditor)) { _ in
            document.openInEditor()
        }
    }

    /// Closes this window if its document is empty (no file loaded). Used
    /// after focusing an existing window from URL-handler paths so SwiftUI's
    /// auto-created host doesn't linger as an orphan welcome page.
    private func closeIfEmpty() {
        guard document.currentURL == nil else { return }
        WindowManager.shared.window(for: document)?.close()
    }
}

// MARK: - Find

/// Per-window state for the in-document Find UI. Owns the query and visibility
/// flag, and forwards the actual search to a `driver` closure that the
/// WebView's coordinator wires up to `WKWebView.find(_:configuration:)`.
final class FindController: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var matchFound = true
    /// Bumped each time the user invokes ⌘F so the FindBar can re-focus its
    /// text field even when it was already on screen.
    @Published private(set) var focusRequest = 0

    private var driver: ((String, Bool) -> Void)?

    func show() {
        isVisible = true
        focusRequest &+= 1
    }

    func hide() { isVisible = false }

    func search() {
        guard !query.isEmpty else {
            matchFound = true
            return
        }
        driver?(query, false)
    }

    func findNext() {
        guard !query.isEmpty else { return }
        driver?(query, false)
    }

    func findPrevious() {
        guard !query.isEmpty else { return }
        driver?(query, true)
    }

    /// Wires the actual search backend (the WebView coordinator) into the
    /// controller. Called from `WebView.makeNSView` / `updateNSView`.
    func attach(_ driver: @escaping (String, Bool) -> Void) {
        self.driver = driver
    }
}

private struct FindBar: View {
    @ObservedObject var controller: FindController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            TextField("Find", text: $controller.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(minWidth: 200)
                .onSubmit { controller.findNext() }
                .onChange(of: controller.query) { _ in
                    controller.search()
                }

            if !controller.query.isEmpty && !controller.matchFound {
                Text("Not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: { controller.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(controller.query.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button(action: { controller.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(controller.query.isEmpty)
            .help("Next match (⌘G)")

            Button(action: { controller.hide() }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .padding(.top, 10)
        .padding(.trailing, 12)
        .onAppear { focused = true }
        .onChange(of: controller.focusRequest) { _ in
            focused = true
        }
    }
}

// MARK: - Window accessor

/// Invisible bridge that hands the hosting NSWindow back to SwiftUI so we can
/// configure AppKit-only knobs (tabbing mode, identifier, etc.) on it.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }
}

// MARK: - Focused-value plumbing

private struct DocumentFocusKey: FocusedValueKey {
    typealias Value = MarkdownDocument
}

private struct FindControllerFocusKey: FocusedValueKey {
    typealias Value = FindController
}

extension FocusedValues {
    var document: MarkdownDocument? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }

    var findController: FindController? {
        get { self[FindControllerFocusKey.self] }
        set { self[FindControllerFocusKey.self] = newValue }
    }
}
