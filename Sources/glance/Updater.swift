import Foundation
import AppKit

/// In-app update checker for Glance.
///
/// Queries the GitHub Releases API, compares against the bundle's
/// `CFBundleShortVersionString`, and — on user confirmation — downloads the
/// `Glance.app.zip` asset, unpacks it, and hands off to a detached shell
/// script that waits for this process to exit, replaces
/// `/Applications/Glance.app`, and relaunches.
///
/// Threading: the public entry point hops to a `Task @MainActor` and performs
/// all AppKit work on the main actor. Network/IO work runs inside that Task;
/// URLSession's `async` APIs are happy to be awaited from any executor.
enum Updater {
    private static let releaseAPI = URL(string: "https://api.github.com/repos/davidunga/glance/releases/latest")!

    /// Menu-item entry point. Async because the GitHub request is, but we
    /// return immediately — the UI is driven entirely from the Task.
    static func checkForUpdates() {
        Task { @MainActor in
            do {
                let release = try await fetchLatestRelease()
                let current = currentVersion()
                // `.numeric` makes "1.0.10" > "1.0.5" (lexicographic wouldn't).
                if current.compare(release.version, options: .numeric) != .orderedAscending {
                    showUpToDate(current: current)
                    return
                }
                await promptAndMaybeInstall(current: current, release: release)
            } catch {
                showError(title: "Update check failed", error: error)
            }
        }
    }

    // MARK: - Release model & network

    private struct Release {
        let version: String        // "1.0.6" (v-stripped)
        let tag: String            // "v1.0.6"
        let notes: String
        let zipURL: URL
    }

    private static func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: releaseAPI, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        req.setValue("Glance/\(currentVersion())", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // Surface URLError (no internet, DNS failure, timeout) with its
            // own message — it's more informative than a generic wrapper.
            throw error
        }

        guard let http = resp as? HTTPURLResponse else {
            throw UpdaterError.message("Unexpected response from GitHub.")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 403, 429:
            throw UpdaterError.message("GitHub rate limit reached. Please try again later.")
        case 404:
            throw UpdaterError.message("No releases found on GitHub.")
        default:
            throw UpdaterError.message("GitHub returned HTTP \(http.statusCode).")
        }

        struct GHAsset: Decodable { let name: String; let browser_download_url: String }
        struct GHRelease: Decodable {
            let tag_name: String
            let body: String?
            let assets: [GHAsset]
        }
        let gh: GHRelease
        do {
            gh = try JSONDecoder().decode(GHRelease.self, from: data)
        } catch {
            throw UpdaterError.message("Couldn't parse GitHub response: \(error.localizedDescription)")
        }
        guard let asset = gh.assets.first(where: { $0.name == "Glance.app.zip" }),
              let zipURL = URL(string: asset.browser_download_url) else {
            throw UpdaterError.message("Release \(gh.tag_name) has no Glance.app.zip asset.")
        }
        return Release(
            version: stripV(gh.tag_name),
            tag: gh.tag_name,
            notes: gh.body ?? "",
            zipURL: zipURL
        )
    }

    // MARK: - Versioning

    private static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static func stripV(_ s: String) -> String {
        s.hasPrefix("v") ? String(s.dropFirst()) : s
    }

    // MARK: - UI: status alerts

    @MainActor
    private static func showUpToDate(current: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date"
        alert.informativeText = "Glance \(current) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - UI: update-available prompt

    @MainActor
    private static func promptAndMaybeInstall(current: String, release: Release) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Glance \(release.version) is available"
        alert.informativeText = "You have \(current). Would you like to install the update now?"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")

        // Release notes go in a scrollable accessory view so they don't
        // stretch the alert off-screen on verbose release bodies.
        alert.accessoryView = makeReleaseNotesView(release.notes)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        await performInstall(release: release)
    }

    @MainActor
    private static func makeReleaseNotesView(_ notes: String) -> NSView {
        let width: CGFloat = 440
        let height: CGFloat = 220

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = notes.isEmpty ? "(No release notes.)" : notes
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        return scroll
    }

    // MARK: - Download + install

    @MainActor
    private static func performInstall(release: Release) async {
        let progress = ProgressWindow(title: "Installing Glance \(release.version)")
        progress.message = "Downloading update…"
        progress.show()

        do {
            let zipPath = try await download(release.zipURL, progress: progress)

            progress.message = "Extracting…"
            let newAppPath = try unzip(at: zipPath)

            progress.message = "Installing…"
            try launchInstaller(newAppPath: newAppPath)

            progress.message = "Relaunching…"
            // Give the installer script a moment to spin up and start waiting
            // on our PID before we terminate — otherwise the script could miss
            // the transition and its PID-wait loop starts seeing a dead PID
            // immediately, which is fine, but the brief grace makes the
            // sequence obviously correct.
            try? await Task.sleep(nanoseconds: 250_000_000)
            NSApp.terminate(nil)
        } catch {
            progress.close()
            showError(title: "Update failed", error: error)
        }
    }

    /// Streams the zip to a temp file, forwarding progress to the window.
    @MainActor
    private static func download(_ url: URL, progress: ProgressWindow) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdaterError.message("Couldn't download update (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }

        let total = http.expectedContentLength
        let tmpDir = try makeScratchDir()
        let zipPath = tmpDir.appendingPathComponent("Glance.app.zip")
        FileManager.default.createFile(atPath: zipPath.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: zipPath) else {
            throw UpdaterError.message("Couldn't open download destination.")
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        var lastTick: TimeInterval = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Update UI at most every ~100ms.
                let now = Date().timeIntervalSince1970
                if now - lastTick > 0.1 {
                    lastTick = now
                    progress.setProgress(received: received, total: total)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress.setProgress(received: received, total: total)
        return zipPath
    }

    /// Unzips `zipPath` next to itself and returns the resulting Glance.app URL.
    private static func unzip(at zipPath: URL) throws -> URL {
        let destDir = zipPath.deletingLastPathComponent().appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: destDir)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zipPath.path, destDir.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw UpdaterError.message("Unzip failed with status \(task.terminationStatus).")
        }

        // The zip produced by release.yml has `Glance.app` at the top level.
        let candidate = destDir.appendingPathComponent("Glance.app")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw UpdaterError.message("Unzipped archive does not contain Glance.app.")
        }
        return candidate
    }

    /// Writes a shell script that:
    ///  1. Waits (≤30s) for this process's PID to exit.
    ///  2. Replaces `/Applications/Glance.app` with the newly unpacked bundle.
    ///  3. Relaunches Glance via `open`.
    ///
    /// The script is spawned with its stdio detached from the parent, so when
    /// the app terminates the script continues and is reparented to launchd.
    private static func launchInstaller(newAppPath: URL) throws {
        let scriptDir = try makeScratchDir()
        let scriptPath = scriptDir.appendingPathComponent("install.sh")
        let logPath = scriptDir.appendingPathComponent("install.log")

        let dest = "/Applications/Glance.app"
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/bash
        # Wait for Glance (pid \(pid)) to exit — up to 30 seconds.
        for _ in $(seq 1 150); do
            if ! kill -0 \(pid) 2>/dev/null; then break; fi
            sleep 0.2
        done
        # Replace the installed bundle. `ditto` preserves xattrs / code signing.
        rm -rf "\(dest)"
        /usr/bin/ditto "\(newAppPath.path)" "\(dest)"
        # Relaunch via LaunchServices so the new process starts outside our
        # (now-dead) sandbox context.
        /usr/bin/open "\(dest)"
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptPath.path
        )

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath.path]
        // Detach stdio so the child doesn't die on SIGPIPE when our streams go
        // away at termination. The log file is handy when something goes wrong
        // — not strictly required for success.
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logPath) {
            task.standardOutput = logHandle
            task.standardError = logHandle
        } else {
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
        }
        task.standardInput = FileHandle.nullDevice
        try task.run()
        // Deliberately do NOT call waitUntilExit — we want the child to
        // outlive us.
    }

    // MARK: - Utilities

    private static func makeScratchDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Error type

    private enum UpdaterError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let m): return m
            }
        }
    }
}

// MARK: - Progress window

/// Small centered window with a label and a progress bar. Lives only while
/// an update is being fetched/installed. Not reusable — construct one per run.
@MainActor
private final class ProgressWindow {
    private let window: NSWindow
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let bar: NSProgressIndicator

    init(title: String) {
        let width: CGFloat = 360
        let height: CGFloat = 120

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Glance"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = content

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: height - 40, width: width - 40, height: 20)
        content.addSubview(titleLabel)

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 20, y: height - 62, width: width - 40, height: 16)
        content.addSubview(messageLabel)

        bar = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: width - 40, height: 14))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        content.addSubview(bar)
    }

    var message: String {
        get { messageLabel.stringValue }
        set { messageLabel.stringValue = newValue }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setProgress(received: Int64, total: Int64) {
        if total > 0 {
            if bar.isIndeterminate {
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = Double(total)
            }
            bar.doubleValue = Double(received)
            let mbReceived = Double(received) / 1_048_576
            let mbTotal = Double(total) / 1_048_576
            messageLabel.stringValue = String(format: "Downloading… %.1f / %.1f MB", mbReceived, mbTotal)
        } else {
            // Unknown total — leave indeterminate spinner running.
            let mbReceived = Double(received) / 1_048_576
            messageLabel.stringValue = String(format: "Downloading… %.1f MB", mbReceived)
        }
    }

    func close() {
        bar.stopAnimation(nil)
        window.orderOut(nil)
        window.close()
    }
}
