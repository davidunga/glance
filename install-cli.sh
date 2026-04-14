#!/usr/bin/env bash
set -euo pipefail

APP_BIN="/Applications/Glance.app/Contents/MacOS/glance"
LINK_NAME="glance"

# 1. Verify the app is installed
if [ ! -f "$APP_BIN" ]; then
    echo "error: $APP_BIN not found."
    echo "       Install Glance.app to /Applications first, then re-run this script."
    exit 1
fi

# 2. Pick a bin directory
#    Prefer ~/.local/bin if it's already on PATH, else try /usr/local/bin,
#    else fall back to ~/.local/bin and tell the user to add it to PATH.
LOCAL_BIN="$HOME/.local/bin"
USR_LOCAL_BIN="/usr/local/bin"

pick_bin_dir() {
    # Check if ~/.local/bin is on PATH
    case ":$PATH:" in
        *":$LOCAL_BIN:"*)
            echo "$LOCAL_BIN"
            return ;;
    esac

    # Check if /usr/local/bin is on PATH and writable (or we can sudo-create it)
    case ":$PATH:" in
        *":$USR_LOCAL_BIN:"*)
            echo "$USR_LOCAL_BIN"
            return ;;
    esac

    # Fall back to ~/.local/bin (may not be on PATH yet)
    echo "$LOCAL_BIN"
}

BIN_DIR="$(pick_bin_dir)"

# 3. Create the bin directory if it doesn't exist
if [ ! -d "$BIN_DIR" ]; then
    if [ "$BIN_DIR" = "$USR_LOCAL_BIN" ]; then
        echo "note: creating $BIN_DIR (requires sudo)"
        sudo mkdir -p "$BIN_DIR"
    else
        mkdir -p "$BIN_DIR"
    fi
fi

LINK_PATH="$BIN_DIR/$LINK_NAME"

# 4. Create/overwrite the symlink (idempotent)
if [ "$BIN_DIR" = "$USR_LOCAL_BIN" ] && [ ! -w "$BIN_DIR" ]; then
    sudo ln -sf "$APP_BIN" "$LINK_PATH"
else
    ln -sf "$APP_BIN" "$LINK_PATH"
fi

# 5. Warn if the chosen directory isn't on PATH
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo "note: $BIN_DIR is not on your PATH."
        echo "      Add this line to your shell profile (~/.zshrc or ~/.bashrc):"
        echo "        export PATH=\"$BIN_DIR:\$PATH\""
        echo "" ;;
esac

echo "ok: glance -> $APP_BIN"
echo "    verify with: glance --render README.md"
