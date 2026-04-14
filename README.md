<h1 align="center">
  <img src="docs/icon.png" width="96" alt="glance icon"><br>
  glance
</h1>

<p align="center">
  A (markdown|code|csv) viewer that doesn't get in your way.  
</p>

<p align="center">
  <img src="docs/screenshot-both.png" alt="screenshots">
</p>

## Install

**[Download the latest release](https://github.com/davidunga/glance/releases/latest)** — unzip and drag to `/Applications`.

Or build from source:

```sh
./build.sh
open glance.app
```

The script fetches highlight.js into `Sources/glance/Resources/`, builds with SwiftPM, assembles a `.app` bundle, and signs it with the entitlements in `glance.entitlements`. Requires Swift 5.9+ and macOS 13+.

Then install:

```sh
cp -R glance.app /Applications/
```

## CLI

```sh
open -a glance file.md         # open a file in the GUI
glance --render file.md        # print rendered HTML to stdout
```

**Install the `glance` command** so you can call it directly from the terminal:

1. Download `glance.app.zip` and `install-cli.sh` from the [latest release](https://github.com/davidunga/glance/releases/latest).
2. Unzip and move `glance.app` to `/Applications`.
3. Run the installer:

```sh
chmod +x install-cli.sh
./install-cli.sh
```

The script symlinks `glance` into `~/.local/bin` (if on PATH) or `/usr/local/bin`, and tells you what to do if neither is on PATH yet.

---

## Built on

- [swift-markdown](https://github.com/apple/swift-markdown) for parsing
- [highlight.js](https://highlightjs.org) for code

## License

MIT — see [LICENSE](LICENSE).
