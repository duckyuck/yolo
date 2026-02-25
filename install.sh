#!/usr/bin/env bash
# Installer for yolo — curl -fsSL https://raw.githubusercontent.com/sourcemagnet/yolo/main/install.sh | bash
set -euo pipefail

YOLO_REPO="sourcemagnet/yolo"
YOLO_HOME="${YOLO_HOME:-$HOME/.yolo}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

BOLD='' DIM='' RESET='' GREEN='' RED='' CYAN=''
if [ -t 1 ]; then
    BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
    GREEN='\033[32m' RED='\033[31m' CYAN='\033[36m'
fi

info()    { echo -e "${CYAN}ℹ${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
error()   { echo -e "${RED}✗${RESET} $1" >&2; }
die()     { error "$1"; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────

check_prereqs() {
    local missing=()

    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        missing+=("bash 4+ (found ${BASH_VERSION}) — brew install bash")
    fi

    if ! command -v docker >/dev/null 2>&1; then
        missing+=("docker — https://docs.docker.com/get-docker/")
    fi

    if ! command -v git >/dev/null 2>&1; then
        missing+=("git — https://git-scm.com/downloads")
    fi

    if ! command -v curl >/dev/null 2>&1; then
        missing+=("curl — apt install curl / brew install curl")
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing+=("jq — brew install jq / apt install jq")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing prerequisites:"
        for m in "${missing[@]}"; do
            echo "  - $m" >&2
        done
        exit 1
    fi
}

# ─── Install ──────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}Installing yolo${RESET}"
    echo ""

    check_prereqs

    # Fetch latest release tag
    info "Fetching latest release..."
    LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${YOLO_REPO}/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/') \
        || die "Could not fetch latest release from GitHub"

    [ -n "$LATEST_TAG" ] || die "Could not determine latest version"
    info "Latest version: v${LATEST_TAG}"

    # Download tarball
    DOWNLOAD_URL="https://github.com/${YOLO_REPO}/releases/download/v${LATEST_TAG}/yolo-${LATEST_TAG}.tar.gz"
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf '$TEMP_DIR'" EXIT

    info "Downloading..."
    curl -fsSL "$DOWNLOAD_URL" | tar xz -C "$TEMP_DIR" \
        || die "Download failed — check https://github.com/${YOLO_REPO}/releases"

    # Install files
    mkdir -p "$YOLO_HOME/bin" "$YOLO_HOME/lib"

    cp "$TEMP_DIR/yolo-${LATEST_TAG}/yolo" "$YOLO_HOME/bin/yolo"
    chmod +x "$YOLO_HOME/bin/yolo"

    for f in docker-compose.yml Dockerfile entrypoint.sh tmux.conf; do
        cp "$TEMP_DIR/yolo-${LATEST_TAG}/$f" "$YOLO_HOME/lib/$f"
    done

    mkdir -p "$YOLO_HOME/lib/hooks"
    cp "$TEMP_DIR/yolo-${LATEST_TAG}/hooks/"*.sh "$YOLO_HOME/lib/hooks/" 2>/dev/null || true
    chmod +x "$YOLO_HOME/lib/hooks/"*.sh 2>/dev/null || true

    echo "$LATEST_TAG" > "$YOLO_HOME/version"
    success "Installed yolo v${LATEST_TAG} to $YOLO_HOME"

    # Add to PATH (idempotent)
    YOLO_BIN="$YOLO_HOME/bin"
    PATH_LINE="export PATH=\"$YOLO_BIN:\$PATH\""

    add_to_shell_rc() {
        local rc="$1"
        [ -f "$rc" ] || return 0
        if ! grep -qF "$YOLO_BIN" "$rc" 2>/dev/null; then
            echo "" >> "$rc"
            echo "# yolo" >> "$rc"
            echo "$PATH_LINE" >> "$rc"
            info "Added to PATH in $(basename "$rc")"
        fi
    }

    add_to_shell_rc "$HOME/.bashrc"
    add_to_shell_rc "$HOME/.zshrc"

    # Done
    echo ""
    success "Installation complete!"
    echo ""
    echo -e "  ${DIM}Restart your shell or run:${RESET}"
    echo -e "    export PATH=\"$YOLO_BIN:\$PATH\""
    echo ""
    echo -e "  ${DIM}Then:${RESET}"
    echo "    cd your-project"
    echo "    yolo up my-session"
    echo ""
}

main "$@"
