import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    let fontSize: Double
    let fontFamily: FontFamily
    let pageWidth: PageWidth
    /// `nil` means the user picked the "System" theme. Forwarded to the
    /// WebView so it can drop its explicit `appearance` and inherit from the
    /// window — that way OS / window appearance changes propagate live.
    let themeOverride: ColorScheme?

    // Each window owns its own document. Sharing one @StateObject at the App
    // level means every window in the WindowGroup renders the same content.
    @StateObject private var document = MarkdownDocument()
    @StateObject private var find = FindController()

    /// Ensures the one-shot initialization in `onAppear` runs at most once
    /// per window, even if SwiftUI re-fires onAppear on view re-appearance.
    /// Without this, a second onAppear could consume a URL from the pending
    /// queue that was meant for a different (yet-to-be-created) window.
    @State private var didInitializeOnce = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(html: document.html,
                    baseURL: document.baseURL,
                    fileURL: document.currentURL,
                    fontSize: fontSize,
                    fontFamily: fontFamily,
                    pageWidth: pageWidth,
                    themeOverride: themeOverride,
                    findController: find)
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
        .background(WindowAccessor(configure: configureWindow))
        .onAppear {
            guard !didInitializeOnce else { return }
            didInitializeOnce = true
            AppDelegate.windowsAppeared += 1
            // Claim the file this window was opened for, if there is one. A
            // window with nothing queued stays blank — no prompt, no landing
            // page. It fills in via ⌘O, a drop, or a file from Finder.
            //
            // The `currentURL` check matters: SwiftUI rebuilds this view when
            // it swaps the window out from under it mid-launch, and a rebuilt
            // view must not grab a second file on top of the one it shows.
            guard document.canClaimFile else { return }
            guard let url = AppDelegate.popURLForNewWindow() else { return }
            document.claim(url)
            DispatchQueue.main.async { document.load(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glanceURLsQueued)) { _ in
            drainQueuedURLs()
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
    }

    /// Files have been queued. An empty window takes exactly one of them;
    /// anything left over is the AppDelegate's problem — it opens a window per
    /// remaining file. Windows never spawn windows, so no two of them can
    /// claim the same file and leave a blank one behind.
    private func drainQueuedURLs() {
        claimUnassignedFile()
    }

    /// Runs whenever SwiftUI attaches or updates this window.
    ///
    /// `register` is idempotent — only the first call per window does real
    /// work; the manager pins tabbingMode = .disallowed and isRestorable =
    /// false so each window stays standalone and fresh launches don't
    /// resurrect the previous session.
    ///
    /// The late pull matters as much: `onAppear` may have run before the file
    /// was queued, and the queue notification may have arrived while SwiftUI
    /// was swapping this window out from under the view. This closure runs on
    /// every update, so it is the one signal that reliably outlives that
    /// churn.
    private func configureWindow(_ window: NSWindow) {
        WindowManager.shared.register(window: window, document: document)
        claimUnassignedFile()
    }

    /// Take one file that has no window of its own yet, if this window is
    /// empty and there is one waiting.
    private func claimUnassignedFile() {
        guard document.canClaimFile, let url = AppDelegate.popUnassignedURL() else { return }
        document.claim(url)
        DispatchQueue.main.async { document.load(url) }
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
        let view = NotifyingView(onMoveToWindow: configure)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }
}

/// Custom NSView that fires `onMoveToWindow` as soon as it gets attached to
/// an NSWindow. `viewDidMoveToWindow` runs SYNCHRONOUSLY on the main thread
/// the moment AppKit wires the view into a window — earlier than any
/// DispatchQueue.main.async-based approach can observe, so the window is in
/// `WindowManager`'s tables before anything asks it what is on screen.
private final class NotifyingView: NSView {
    let onMoveToWindow: (NSWindow) -> Void

    init(onMoveToWindow: @escaping (NSWindow) -> Void) {
        self.onMoveToWindow = onMoveToWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            onMoveToWindow(window)
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
