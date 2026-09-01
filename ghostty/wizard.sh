#!/usr/bin/env bash
# ./wizard.sh

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo -e "\033[1;31m==> ERROR:\033[0m Do not run this script as root or with sudo." >&2
    echo -e "\033[1;31m==> ERROR:\033[0m The script will prompt for sudo internally when installing system packages via dnf." >&2
    exit 1
fi

PREFIX="$HOME/.local"
TEMP_DIR=""

# Let Bash natively evaluate the token from .bashrc if it isn't already in the environment
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$HOME/.bashrc" ]; then
    token_line=$(grep -E '^(export )?GITHUB_TOKEN=' "$HOME/.bashrc" | tail -n 1 || true)
    if [ -n "$token_line" ]; then
        eval "$token_line"
        export GITHUB_TOKEN
    fi
fi

log_info() {
    echo -e "\033[1;34m==>\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m==>\033[0m $1"
}

log_error() {
    echo -e "\033[1;31m==> ERROR:\033[0m $1" >&2
}

cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR:-}" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

check_github_rate_limit() {
    local curl_opts=(-s)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_opts+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "https://api.github.com/rate_limit" 2>/dev/null || true)
    
    if [ -z "$response" ]; then
        return 0 
    fi

    if echo "$response" | grep -q '"message": *"Bad credentials"'; then
        log_error "GitHub API rejected the token (Bad credentials)."
        log_error "Please check the GITHUB_TOKEN in your ~/.bashrc"
        return 1
    fi
    
    local remaining
    remaining=$(echo "$response" | grep -A 5 '"rate":' | grep '"remaining":' | grep -oE '[0-9]+' | head -n 1 || echo "")
    
    if [ "$remaining" = "0" ]; then
        local reset
        reset=$(echo "$response" | grep -A 5 '"rate":' | grep '"reset":' | grep -oE '[0-9]+' | head -n 1 || echo "0")
        local current_time
        current_time=$(date +%s)
        local wait_seconds=$((reset - current_time))
        
        if [ "$wait_seconds" -gt 0 ]; then
            local wait_minutes=$((wait_seconds / 60))
            local wait_rem=$((wait_seconds % 60))
            log_error "GitHub API rate limit exceeded (0 requests remaining)."
            log_error "Please wait ${wait_minutes}m ${wait_rem}s before trying again."
        else
            log_error "GitHub API rate limit exceeded, but should reset momentarily."
        fi
        return 1
    fi
    
    return 0
}

get_latest_version() {
    if ! check_github_rate_limit; then
        return 1
    fi

    local curl_opts=(-s)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_opts+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    
    local response
    response=$(curl "${curl_opts[@]}" "https://api.github.com/repos/ghostty-org/ghostty/tags")
    
    if echo "$response" | grep -q '"name":'; then
        local version
        version=$(echo "$response" | grep '"name":' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
        
        if [ -n "$version" ]; then
            echo "$version"
        else
            log_error "Could not find a valid semver tag (like 1.0.0) in the GitHub repository." >&2
            return 1
        fi
    else
        local error_msg
        error_msg=$(echo "$response" | grep '"message":' | sed -E 's/.*"message": *"([^"]+)".*/\1/' | head -n 1 || echo "Unknown API error")
        log_error "GitHub API returned an error: $error_msg" >&2
        return 1
    fi
}

get_installed_version() {
    if [ -f "$PREFIX/bin/ghostty" ] && [ -x "$PREFIX/bin/ghostty" ]; then
        "$PREFIX/bin/ghostty" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
    else
        echo "none"
    fi
}

cmd_install() {
    log_info "Installing system dependencies via DNF..."
    sudo dnf install -y gtk4-devel gtk4-layer-shell-devel libadwaita-devel gettext tar xz

    log_info "Resolving latest Ghostty version from GitHub..."
    local latest
    if ! latest=$(get_latest_version) || [ -z "$latest" ]; then
        log_error "Failed to fetch latest version information."
        exit 1
    fi
    log_info "Target version: ${latest}"

    TEMP_DIR=$(mktemp -d)
    pushd "$TEMP_DIR" >/dev/null

    log_info "Downloading Ghostty source tarball..."
    if ! curl -sL -f -O "https://release.files.ghostty.org/${latest}/ghostty-${latest}.tar.gz"; then
        log_error "Failed to download Ghostty source tarball."
        exit 1
    fi

    log_info "Extracting Ghostty source..."
    tar -xf "ghostty-${latest}.tar.gz"
    cd "ghostty-${latest}"

    local zig_version
    zig_version=$(grep -oP '(minimum_zig_version|min_zig_string|zig_version)\s*=\s*"\K[0-9]+\.[0-9]+\.[0-9]+' build.zig 2>/dev/null | head -n 1 || true)
    
    if [ -z "$zig_version" ]; then
        zig_version="0.15.2"
        log_info "Could not detect required Zig version, defaulting to ${zig_version}"
    else
        log_info "Detected required Zig version: ${zig_version}"
    fi

    # Zig inverted their OS/Arch naming convention midway through their releases. 
    # We attempt both naming schemes to ensure it always successfully downloads.
    local zig_new_format="zig-x86_64-linux-${zig_version}.tar.xz"
    local zig_old_format="zig-linux-x86_64-${zig_version}.tar.xz"
    local zig_tarball=""

    log_info "Downloading Zig compiler v${zig_version}..."
    if curl -sL -f -O "https://ziglang.org/download/${zig_version}/${zig_new_format}"; then
        zig_tarball="${zig_new_format}"
    elif curl -sL -f -O "https://ziglang.org/download/${zig_version}/${zig_old_format}"; then
        zig_tarball="${zig_old_format}"
    else
        log_error "Failed to download Zig compiler. Both naming schemes returned 404."
        exit 1
    fi

    log_info "Extracting Zig compiler..."
    tar -xf "${zig_tarball}"
    local zig_dir="${zig_tarball%.tar.xz}"
    export PATH="$PWD/${zig_dir}:$PATH"

    log_info "Compiling and installing Ghostty... (this may take a few minutes)"
    if zig build -p "$PREFIX" -Doptimize=ReleaseFast; then
        log_success "Ghostty ${latest} successfully installed to ${PREFIX}!"
    else
        log_error "Failed to compile Ghostty."
        exit 1
    fi
    
    popd >/dev/null
}

cmd_uninstall() {
    if [ -z "$PREFIX" ] || [ "$PREFIX" = "/" ]; then
        log_error "Safety check failed. PREFIX is empty or root."
        exit 1
    fi

    log_info "Removing Ghostty files from ${PREFIX}..."

    rm -f "$PREFIX/bin/ghostty"
    rm -rf "$PREFIX/include/ghostty"
    rm -f "$PREFIX/lib/libghostty-vt.so"
    rm -rf "$PREFIX/share/ghostty"
    rm -f "$PREFIX/share/applications/com.mitchellh.ghostty.desktop"
    rm -f "$PREFIX/share/kio/servicemenus/com.mitchellh.ghostty.desktop"
    
    if [ -d "$PREFIX/share/icons/hicolor" ]; then
        find "$PREFIX/share/icons/hicolor" -name "com.mitchellh.ghostty*.png" -type f -delete 2>/dev/null || true
        find "$PREFIX/share/icons/hicolor" -name "com.mitchellh.ghostty*.svg" -type f -delete 2>/dev/null || true
    fi
    
    rm -f "$PREFIX/share/bash-completion/completions/ghostty.bash"
    rm -f "$PREFIX/share/bash-completion/completions/ghostty"
    rm -f "$PREFIX/share/zsh/site-functions/_ghostty"
    rm -f "$PREFIX/share/fish/vendor_completions.d/ghostty.fish"
    rm -rf "$PREFIX/share/terminfo/g/ghostty"
    rm -rf "$PREFIX/share/terminfo/x/xterm-ghostty"
    rm -f "$PREFIX/share/man/man1/ghostty.1"
    rm -f "$PREFIX/share/man/man5/ghostty.5"
    rm -rf "$PREFIX/share/bat/syntaxes/ghostty.sublime-syntax"

    log_success "Ghostty successfully uninstalled."
}

cmd_check() {
    local latest
    if ! latest=$(get_latest_version) || [ -z "$latest" ]; then
        log_error "Failed to fetch latest version from GitHub API."
        exit 1
    fi

    local installed
    installed=$(get_installed_version)

    if [ "$installed" = "none" ]; then
        echo "Installed: None"
        echo "Latest:    $latest"
    elif [ "$installed" != "$latest" ]; then
        echo "Installed: $installed"
        echo "Latest:    $latest (Update available)"
    else
        echo "Installed: $installed (Up to date)"
    fi
}

cmd_update() {
    log_info "Checking for updates..."
    local latest
    if ! latest=$(get_latest_version) || [ -z "$latest" ]; then
        log_error "Failed to fetch latest version from GitHub API."
        exit 1
    fi

    local installed
    installed=$(get_installed_version)

    if [ "$installed" = "none" ]; then
        log_info "Ghostty is not installed. Initiating installation."
        cmd_install
    elif [ "$installed" != "$latest" ]; then
        log_info "Updating Ghostty from ${installed} to ${latest}..."
        cmd_install
    else
        log_success "Ghostty is already up to date (${installed})."
    fi
}

if [ $# -eq 0 ]; then
    echo "Usage: $0 {install|uninstall|check|update}"
    exit 1
fi

case "$1" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    check) cmd_check ;;
    update) cmd_update ;;
    *) 
        echo "Usage: $0 {install|uninstall|check|update}"
        exit 1 
        ;;
esac