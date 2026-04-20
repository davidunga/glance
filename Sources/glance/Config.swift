import AppKit
import Foundation
import SwiftUI

// MARK: - Config schema

/// User-editable JSON config. Lives at
/// `~/Library/Containers/local.glance/Data/Library/Application Support/Glance/config.json`.
/// Recents and per-file scroll positions are intentionally NOT here — those are
/// app state, not user preferences, and stay in UserDefaults.
struct EditorRule: Codable, Equatable {
    /// Absolute path to the editor's `.app` bundle.
    var app: String
    /// File extensions this rule applies to (lowercase, no dot). Use `"*"` as
    /// a catch-all fallback.
    var extensions: [String]
}

// MARK: - Store

/// Singleton config store. `@Published` properties mirror the JSON file and
/// auto-save on every change. Reloads from disk whenever the app becomes
/// active, so external edits take effect on the next window focus.
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    @Published var theme: Theme = .system              { didSet { persist() } }
    @Published var fontSize: Double = FontSize.default { didSet { persist() } }
    @Published var fontFamily: FontFamily = .sans      { didSet { persist() } }
    @Published var editor: [EditorRule] = []           { didSet { persist() } }

    let configURL: URL

    /// Gate for persisting. Flipped on once the initial load (and any
    /// migration / seeding) is complete — otherwise the very first `didSet`
    /// from the load path would spuriously rewrite the file.
    private var loaded = false
    /// Set while reloading from disk so the resulting `@Published` assignments
    /// don't trigger a resave.
    private var suppressSave = false

    private init() {
        self.configURL = Self.makeConfigURL()
        loadOrSeed()
        loaded = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    // MARK: Public API

    /// Return the editor .app URL that should open `fileURL`, or nil if no
    /// rule matches (caller should fall back to the system default).
    func editorApp(for fileURL: URL) -> URL? {
        let ext = fileURL.pathExtension.lowercased()
        // Exact-extension rules first, then the `"*"` catch-all.
        if let rule = editor.first(where: { $0.extensions.contains { $0.lowercased() == ext } }) {
            return URL(fileURLWithPath: rule.app)
        }
        if let rule = editor.first(where: { $0.extensions.contains("*") }) {
            return URL(fileURLWithPath: rule.app)
        }
        return nil
    }

    /// Record `appPath` as the editor for files with `ext`. If the extension
    /// was previously mapped to a different editor, it's moved to this one.
    /// Rules whose extension lists become empty are pruned.
    func setEditor(appPath: String, forExtension ext: String) {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return }
        var rules = editor
        for i in rules.indices {
            rules[i].extensions.removeAll { $0.lowercased() == ext }
        }
        if let i = rules.firstIndex(where: { $0.app == appPath }) {
            rules[i].extensions.append(ext)
        } else {
            rules.append(EditorRule(app: appPath, extensions: [ext]))
        }
        rules.removeAll { $0.extensions.isEmpty }
        editor = rules
    }

    /// Show the config file in Finder. Creates it first if missing.
    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            persistNow()
        }
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    // MARK: Load / save

    private static func makeConfigURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Glance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    private func loadOrSeed() {
        if let payload = readFromDisk() {
            apply(payload)
            return
        }
        // No file yet — migrate any pre-existing `@AppStorage` values once,
        // then write the seed file.
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "theme"), let t = Theme(rawValue: raw) { theme = t }
        let fs = d.double(forKey: "fontSize")
        if fs >= FontSize.min && fs <= FontSize.max { fontSize = fs }
        if let raw = d.string(forKey: "fontFamily"), let f = FontFamily(rawValue: raw) { fontFamily = f }
        persistNow()
    }

    private func readFromDisk() -> Payload? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func apply(_ p: Payload) {
        suppressSave = true
        defer { suppressSave = false }
        if let v = p.theme      { theme = v }
        if let v = p.fontSize   { fontSize = v }
        if let v = p.fontFamily { fontFamily = v }
        if let v = p.editor     { editor = v }
    }

    private func persist() {
        guard loaded, !suppressSave else { return }
        persistNow()
    }

    private func persistNow() {
        let payload = Payload(theme: theme,
                              fontSize: fontSize,
                              fontFamily: fontFamily,
                              editor: editor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    @objc private func appDidBecomeActive() {
        guard let fresh = readFromDisk() else { return }
        apply(fresh)
    }

    /// Codable mirror of the store. All optional so a partial JSON (user
    /// deleted a key) still decodes — missing keys keep their current value.
    private struct Payload: Codable {
        var theme: Theme?
        var fontSize: Double?
        var fontFamily: FontFamily?
        var editor: [EditorRule]?
    }
}
