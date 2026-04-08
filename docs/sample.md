# glance

A native macOS Markdown viewer.

> Open a file. Read it. Close it. That's the whole pitch.

## Features

- **Live reload** — files re-render the moment you save them.
- **Tabs** — `⌘T` opens a new tab in the same window.
- **Find in document** — `⌘F`, with `⌘G` / `⇧⌘G` to step through matches.
- **Print & export to PDF** — `⌘P` and `⇧⌘E`.
- **Source code too** — drop a `.py`, `.swift`, `.rs`, etc. for syntax-highlighted reading.

## Code

```swift
struct GlanceApp: App {
    @AppStorage("theme") private var theme: Theme = .system

    var body: some Scene {
        WindowGroup(for: UUID.self) { _ in
            ContentView(themeOverride: theme.colorScheme)
        }
    }
}
```

```python
def fib(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

## Tables

| Shortcut | Action          |
| -------- | --------------- |
| `⌘O`     | Open file       |
| `⌘T`     | New tab         |
| `⌘F`     | Find            |
| `⌘P`     | Print           |
| `⇧⌘E`    | Export as PDF   |

## Lists

1. Markdown rendering via [swift-markdown](https://github.com/apple/swift-markdown).
2. Syntax highlighting via [highlight.js](https://highlightjs.org).
3. Sandboxed `.app` bundle, ad-hoc signed.

- [x] Tabs
- [x] Find
- [x] Live reload
- [ ] Vim mode (probably never)
