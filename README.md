<h1 align="center">
  <img src="docs/icon.png" width="128" alt="glance icon"><br>
  glance
</h1>

<p align="center">
  A native macOS Markdown viewer. Open a file. Read it. Close it.
</p>

<p align="center">
  <img src="docs/screenshot-light.png#gh-light-mode-only" alt="glance in light mode">
  <img src="docs/screenshot-dark.png#gh-dark-mode-only" alt="glance in dark mode">
</p>

## Features

- **Live reload** — files re-render the moment you save them
- **Tabs** — `⌘T` opens a new tab in the same window
- **Find in document** — `⌘F`, with `⌘G` / `⇧⌘G` to step through matches
- **Print & export to PDF** — `⌘P` and `⇧⌘E`
- **Source code too** — drop a `.py`, `.swift`, `.rs`, etc. for syntax-highlighted reading
- **Drag & drop** to open, **Open Recent** to come back
- **Sandboxed** `.app` bundle, ad-hoc signed for local use

## Build

```sh
./build.sh
open glance.app
```

The script fetches highlight.js into `Sources/glance/Resources/`, builds with SwiftPM, assembles a `.app` bundle, and signs it with the entitlements in `glance.entitlements`. Requires Swift 5.9+ and macOS 13+.

To install:

```sh
cp -R glance.app /Applications/
```

## Usage

```sh
open -a glance file.md         # open a file
glance --render file.md        # CLI: print rendered HTML to stdout
```

Set glance as the default `.md` opener via Finder ▸ Get Info ▸ Open With ▸ Change All.

### Shortcuts

| Shortcut | Action |
| -------- | ------ |
| `⌘O`     | Open file |
| `⌘T`     | New tab |
| `⌘F`     | Find |
| `⌘G` / `⇧⌘G` | Next / previous match |
| `⌘R`     | Reload |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘P`     | Print |
| `⇧⌘E`    | Export as PDF |

## Built on

- [swift-markdown](https://github.com/apple/swift-markdown) for parsing
- [highlight.js](https://highlightjs.org) for code

## License

MIT — see [LICENSE](LICENSE).
