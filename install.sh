#!/usr/bin/env bash
#
# Oats installer — builds from source and installs the app and the CLI.
#
#   curl -fsSL https://raw.githubusercontent.com/yuvrajadhikari/oats/main/install.sh | bash
#
# Building locally is not a workaround, it is the point: an app compiled on your
# own machine never carries a quarantine flag, so there is no Gatekeeper wall and
# nothing to strip. It also means the binary you run is the source you can read.
#
# Re-running updates an existing install. `--uninstall` removes everything.
#
# Overrides, mostly for testing:
#   OATS_SRC      where the checkout lives      (default ~/.oats/src)
#   OATS_APP_DIR  where Oats.app is installed   (default /Applications)
#   OATS_BIN_DIR  where the oats CLI is linked  (default /usr/local/bin)
set -euo pipefail

REPO="${OATS_REPO:-https://github.com/yuvrajadhikari/oats.git}"
SRC="${OATS_SRC:-$HOME/.oats/src}"
APP_DIR="${OATS_APP_DIR:-/Applications}"
BIN_DIR="${OATS_BIN_DIR:-/usr/local/bin}"

if [ -t 1 ]; then
    bold=$(tput bold); dim=$(tput dim); red=$(tput setaf 1); green=$(tput setaf 2); reset=$(tput sgr0)
else
    bold=""; dim=""; red=""; green=""; reset=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
warn() { printf '%swarning:%s %s\n' "$red" "$reset" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

uninstall() {
    step "Removing Oats"
    for app in "$APP_DIR/Oats.app" "$HOME/Applications/Oats.app"; do
        [ -e "$app" ] && rm -rf "$app" && say "  removed $app"
    done
    for cli in "$BIN_DIR/oats" "$HOME/.local/bin/oats"; do
        [ -L "$cli" ] || [ -f "$cli" ] && rm -f "$cli" && say "  removed $cli"
    done

    # Only ever the checkout itself. Deleting its parent would be correct for
    # the default ~/.oats/src and catastrophic for anyone who pointed OATS_SRC
    # at, say, ~/code/oats — that would take ~/code with it. The parent is
    # cleaned up only if removing the checkout left it empty.
    if [ -d "$SRC" ]; then
        rm -rf "$SRC" && say "  removed $SRC"
        rmdir "$(dirname "$SRC")" 2>/dev/null && say "  removed $(dirname "$SRC")"
    fi
    say ""
    say "Your meetings in ~/Documents/Oats were left alone. They are plain"
    say "Markdown and JSON, and they are yours."
    exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# ── Preflight ────────────────────────────────────────────────────────────────
# Checked up front and explained, because every one of these fails confusingly
# later: a wrong macOS gives screenfuls of missing-symbol errors, and a missing
# toolchain gives "swift: command not found" halfway through a build.

[ "$(uname -s)" = "Darwin" ] || die "Oats is macOS only."

if [ "$(uname -m)" != "arm64" ]; then
    die "Oats needs Apple Silicon. This Mac reports $(uname -m)."
fi

macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 26 ]; then
    die "Oats needs macOS 26 or newer; this is $(sw_vers -productVersion).
       The on-device speech and language models it depends on do not exist
       on earlier versions, so there is no fallback to offer."
fi

if ! command -v git >/dev/null 2>&1; then
    die "git not found. Run: xcode-select --install"
fi

if ! command -v swift >/dev/null 2>&1; then
    die "The Swift toolchain was not found. Install the Command Line Tools:
           xcode-select --install
       then run this again."
fi

# ── Source ───────────────────────────────────────────────────────────────────
if [ -d "$SRC/.git" ]; then
    step "Updating $SRC"
    git -C "$SRC" fetch --quiet origin
    git -C "$SRC" reset --hard --quiet origin/main
else
    step "Cloning into $SRC"
    mkdir -p "$(dirname "$SRC")"
    rm -rf "$SRC"
    git clone --quiet --depth 1 "$REPO" "$SRC"
fi

# ── Build ────────────────────────────────────────────────────────────────────
step "Building the engine and CLI (first build takes a minute or two)"
swift build -c release --package-path "$SRC/OatsKit"

step "Building Oats.app"
( cd "$SRC/OatsApp" && ./scripts/bundle.sh release >/dev/null )

# ── Install ──────────────────────────────────────────────────────────────────
install_app() {
    local target="$1"
    rm -rf "$target/Oats.app"
    # ditto rather than cp: it preserves the bundle's metadata and the ad-hoc
    # signature, which a plain recursive copy can disturb.
    ditto "$SRC/OatsApp/build/Oats.app" "$target/Oats.app"
}

step "Installing"
if [ -w "$APP_DIR" ] || [ "$(id -u)" = "0" ]; then
    install_app "$APP_DIR"
    installed_app="$APP_DIR/Oats.app"
else
    mkdir -p "$HOME/Applications"
    install_app "$HOME/Applications"
    installed_app="$HOME/Applications/Oats.app"
    warn "$APP_DIR is not writable, so Oats went to ~/Applications instead."
fi
say "  $installed_app"

cli_note=""
if [ -w "$BIN_DIR" ]; then
    ln -sf "$SRC/OatsKit/.build/release/oats" "$BIN_DIR/oats"
    say "  $BIN_DIR/oats"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$SRC/OatsKit/.build/release/oats" "$HOME/.local/bin/oats"
    say "  $HOME/.local/bin/oats"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) cli_note="Add ~/.local/bin to your PATH to use the 'oats' command." ;;
    esac
fi

# ── Done ─────────────────────────────────────────────────────────────────────
say ""
printf '%sOats is installed.%s\n' "$green" "$reset"
say ""
say "  open -a Oats            start the app"
say "  oats doctor             check permissions and models"
say ""
say "${dim}On first run macOS will ask for microphone and system-audio access;"
say "both are needed to hear the two sides of a call. Note enhancement also"
say "needs Apple Intelligence enabled in System Settings — without it you"
say "still get transcripts, just not written-up notes. 'oats doctor' will"
say "tell you either way.${reset}"
[ -n "$cli_note" ] && { say ""; warn "$cli_note"; }
say ""
say "${dim}Update: re-run this installer.  Remove: install.sh --uninstall${reset}"
