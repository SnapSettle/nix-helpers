# ==============================================================================
# NixOS Flake Rebuild Tool
# ==============================================================================
rbf() {
  local actions=() extra_args=() user_specified_action=false
  local do_update=false do_update_only=false do_fmt=false do_fmt_only=false do_push=false
  local debug_mode=false hostname="" impure_flag="--impure"
  local config_dir="" dir_owner use_sudo_for_local=false is_git=false
  local real_user git_env_flags files msg target_link gen action
  local success=true flake_path="."

  usage() {
    cat << 'EOF'
rbf - NixOS Flake Rebuild Tool

Usage: rbf [action] [options] [-- extra_args]

Actions:
  boot|switch|test        NixOS rebuild action to perform (default: boot)

Options:
  -h, --help               Show this help message
  --d, --debug              DEBUG mode: Show detailed command execution
  --up, --update-all       Update all flake inputs before rebuilding
  --up-only, --update-only Quickly update flake inputs and exit
  --p, --push              Push git commits to remote after successful rebuild
  --fmt, --format          Run 'nix fmt' in the flake directory before rebuilding
  --fmt-only               Only format files in the flake directory and exit
  --hostname <name>        Specify a specific hostname configuration from the flake
  --d, --debug              DEBUG mode: Show detailed command execution

Extra arguments are passed to 'nixos-rebuild'.
EOF
  }

  fail() {
    echo "🛑 $*" >&2
  }

  # --- Cache Recovery Helpers ---
  purge_all_tarball_caches() {
    echo "🧹 Purging all Nix tarball caches..."
    rm -rf ~/.cache/nix/tarballs/ 2> /dev/null || true
    if [[ "$EUID" -ne 0 ]]; then
      sudo rm -rf /root/.cache/nix/tarballs/ 2> /dev/null || true
    fi
  }

  handle_cache_corruption() {
    echo ""
    echo "⚠️  Detected corrupted Nix download cache (Truncated tar archive)."
    echo "Choose how to resolve this:"
    echo "  1) Smart repair (Scan & delete ONLY corrupted cache files - recommended)"
    echo "  2) Full purge  (Wipe entire nix tarball cache directory)"
    echo "  3) Skip        (Abort and handle manually)"
    echo ""

    # Prompt user for choice, defaulting to 1
    read -rp "Select an option [1-3] (default: 1): " choice < /dev/tty
    choice=${choice:-1}

    case "$choice" in
    1)
      echo "🔍 Scanning tarball caches for corrupted archives..."
      local cache_dirs=("$HOME/.cache/nix/tarballs")
      [[ "$EUID" -ne 0 ]] && cache_dirs+=("/root/.cache/nix/tarballs")

      local found_corrupted=false
      for cdir in "${cache_dirs[@]}"; do
        [[ -d "$cdir" ]] || continue
        while IFS= read -r file; do
          if [[ -f "$file" ]] && ! gzip -t "$file" 2> /dev/null; then
            echo "🧹 Removing corrupted file: $file"
            if [[ "$cdir" == "/root/"* && "$EUID" -ne 0 ]]; then
              sudo rm -f "$file" "$file.info" 2> /dev/null || true
            else
              rm -f "$file" "$file.info" 2> /dev/null || true
            fi
            found_corrupted=true
          fi
        done < <(find "$cdir" -type f 2> /dev/null)
      done

      if [[ "$found_corrupted" == false ]]; then
        echo "⚠️  No specific corrupted file identified by scanner. Falling back to full purge."
        purge_all_tarball_caches
      fi
      ;;
    2)
      purge_all_tarball_caches
      ;;
    *)
      echo "Skipping cache cleanup."
      return 1
      ;;
    esac
  }

  run_nix_with_retry() {
    local log_file
    log_file=$(mktemp)

    # Pipefail locally to catch failure before the pipe to tee
    set -o pipefail
    if "$@" 2>&1 | tee "$log_file"; then
      set +o pipefail
      rm -f "$log_file"
      return 0
    fi
    set +o pipefail

    # Intercept cache corruption error
    if grep -q "Truncated tar archive detected" "$log_file"; then
      rm -f "$log_file"
      if handle_cache_corruption; then
        echo "🔄 Retrying Nix command..."
        "$@"
        return $?
      fi
      return 1
    fi

    rm -f "$log_file"
    return 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      usage
      return 0
      ;;
    --d | --debug)
      debug_mode=true
      shift
      ;;
    boot | switch | test)
      actions+=("$1")
      user_specified_action=true
      shift
      ;;
    --up | --update-all)
      do_update=true
      shift
      ;;
    --up-only | --update-only)
      do_update_only=true
      shift
      ;;
    --fmt | --format)
      do_fmt=true
      shift
      ;;
    --fmt-only)
      do_fmt_only=true
      do_fmt=true
      shift
      ;;
    --p | --push)
      do_push=true
      shift
      ;;
    --hostname)
      if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
        fail "Missing value for --hostname"
        return 1
      fi
      hostname="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        extra_args+=("$1")
        shift
      done
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
    esac
  done

  if [[ "$user_specified_action" == false ]]; then
    actions+=("boot")
  fi

  for dir in "." "/etc/nixos"; do
    if [[ -f "$dir/flake.nix" ]]; then
      config_dir="$dir"
      break
    fi
  done

  if [[ -z "$config_dir" ]]; then
    fail "Could not find a NixOS flake directory."
    return 1
  fi

  dir_owner=$(stat -c "%U" "$config_dir")
  if [[ "$dir_owner" == "root" && "$EUID" -ne 0 ]]; then
    echo "ℹ️  Flake directory '$config_dir' is owned by root. Using 'sudo' for local modifications."
    use_sudo_for_local=true
  fi

  local_cmd() {
    if [[ "$use_sudo_for_local" == true ]]; then
      sudo "$@"
    else
      "$@"
    fi
  }

  pushd "$config_dir" > /dev/null || return 1
  trap 'popd > /dev/null' RETURN

  if local_cmd git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    is_git=true
    local_cmd git add -A
  else
    echo "🛑 Not a git repository. Continuing anyway..."
  fi

  if [[ "$do_fmt" == true ]]; then
    echo "Formatting files..."
    if ! local_cmd nix fmt 2> /dev/null; then
      echo "ℹ️  Flake has no formatter defined. Falling back to nixfmt-rfc-style..."
      if ! local_cmd nix run "nixpkgs#nixfmt-tree" -- --tree-root "$config_dir"; then
        fail "Formatting failed."
        return 1
      fi
    fi
    [[ "$is_git" == true ]] && local_cmd git add -A
  fi

  if [[ "$do_update" == true || "$do_update_only" == true ]]; then
    echo "Updating all flake inputs..."
    run_nix_with_retry local_cmd nix flake update
    [[ "$is_git" == true ]] && local_cmd git add -A
  fi

  if [[ "$user_specified_action" == false && ("$do_update_only" == true || "$do_fmt_only" == true) ]]; then
    echo "✅ Success!"
    return 0
  fi

  real_user=${SUDO_USER:-$USER}
  git_env_flags=(-c "user.name=$real_user" -c "user.email=$real_user@$(hostname)")

  if [[ "$is_git" == true ]] && ! local_cmd git diff --cached --quiet; then
    files=$(local_cmd git diff --cached --name-only | paste -sd ", " -)
    msg="Pre-rebuild (${actions[*]}): $files"
    echo "Committing changes: $msg"
    local_cmd git "${git_env_flags[@]}" commit -m "$msg" > /dev/null
  fi

  if [[ "$debug_mode" == true ]]; then
    set -x
    trap 'set +x; popd > /dev/null 2>&1 || true' RETURN
  fi

  if [[ -n "$hostname" ]]; then
    flake_path=".#$hostname"
  else
    flake_path=".#$(hostname)"
  fi

  if [[ "$debug_mode" == true ]]; then
    echo "🐛 [DEBUG] Config Dir:  $config_dir" >&2
    echo "🐛 [DEBUG] Flake Path:  $flake_path" >&2
    echo "🐛 [DEBUG] Action(s):   ${actions[*]}" >&2
    echo "🐛 [DEBUG] Extra Args:  ${extra_args[*]}" >&2
  fi

  for action in "${actions[@]}"; do
    echo "Executing NixOS $action..."
    run_nix_with_retry sudo nixos-rebuild "$action" --flake "$flake_path" "$impure_flag" "${extra_args[@]}" || {
      success=false
      break
    }
  done

  if [[ "$success" == true ]]; then
    if [[ "$is_git" == true ]]; then
      target_link=$(readlink /nix/var/nix/profiles/system 2> /dev/null || true)
      gen="?"
      [[ "$target_link" =~ system-([0-9]+)-link ]] && gen="${BASH_REMATCH[1]}"
      local_cmd git "${git_env_flags[@]}" commit --amend -m "Gen $gen (${actions[*]}): finalized" > /dev/null 2>&1

      if [[ "$do_push" == true ]]; then
        echo "Pushing changes to remote git repository..."
        local_cmd git push || echo "⚠️ Warning: Git push failed, but build succeeded."
      fi

      if [[ "${actions[0]}" == "boot" ]]; then
        echo "✅ Success! Generation $gen set as boot default (active on next reboot)."
      else
        echo "✅ Success! Generation $gen is now active."
      fi
    else
      echo "✅ Success! (No Git history to update)."
    fi
  else
    echo "🛑 Aborted."
    if [[ "$is_git" == true ]] && local_cmd git log -1 --pretty=%s | grep -q '^Pre-rebuild'; then
      echo "🔙 Rolling back temporary Git commit..."
      local_cmd git reset --soft HEAD~1
    fi
  fi

  [[ "$success" == true ]]
}

# ==============================================================================
# Get IP Addresses of Active Network Interfaces
# ==============================================================================

whatsmyip() {
  local cyan='\033[1;36m'
  local reset='\033[0m'

  # Removed 'scope global' to allow showing link-local addresses if needed
  ip -brief addr show | awk -v c_cyan="$cyan" -v c_reset="$reset" '
        $1 ~ /^(lo|docker|veth|br-|vboxnet|virbr|tailscale|tun|tap|wireguard|wg)/ { next }
        $2 ~ /^UP/ && NF >= 3 {
            printf "%s> %s%s\n", c_cyan, $1, c_reset
            for (i = 3; i <= NF; i++) {
                family = ($i ~ /:/) ? "inet6" : "inet"
                printf "\t%s %s\n", family, $i
            }
        }
    '
}

# ==============================================================================
# YouTube Media Downloader (Legacy & Modern)
# ==============================================================================

ytmd-legacy() {
  local url=""
  local format="mp3"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --format)
      format="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
    esac
  done

  if [ -z "$url" ]; then
    echo "🛑 Please provide a YouTube URL."
    echo "Usage: ytmd-legacy <URL> [--format <format>]"
    return 1
  fi

  nix-shell -p yt-dlp ffmpeg --run "yt-dlp -x --audio-format \"$format\" \"$url\""
}

ytmd() {
  local url=""
  local format="mp3"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --format)
      format="$2"
      shift 2
      ;;
    *)
      url="$1"
      shift
      ;;
    esac
  done

  if [ -z "$url" ]; then
    echo "Error: Please provide a YouTube URL."
    echo "Usage: ytmd <URL> [--format <format>]"
    return 1
  fi

  nix shell nixpkgs#yt-dlp nixpkgs#ffmpeg -c yt-dlp -x --audio-format "$format" "$url"
}

# ==============================================================================
# Interactive File Finder & Editor
# ==============================================================================
fzf-open-editor() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: fzf-open-editor"
    echo "Interactive file search and open tool using fzf and bat."
    return 0
  fi

  # Direct check for bat; fallback to standard cat if not installed
  local preview_cmd="cat {}"
  if command -v bat &> /dev/null; then
    preview_cmd="bat --style=numbers --color=always --line-range :500 {}"
  fi

  local file
  file=$(fzf --preview "$preview_cmd" 2> /dev/null)

  if [[ -n "$file" ]]; then
    ${EDITOR:-nano} "$file"
  fi

  # Reset terminal cursor states cleanly
  bind '"\e[0n": ""'
  printf '\e[5n'
}

# Bind Ctrl+E to instantly trigger the interactive editor window
bind -x '"\C-e": fzf-open-editor'

e() {
  local custom_editor=""
  local file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      echo "e - Quick Editor"
      echo ""
      echo "Usage: e [options] <file>"
      echo ""
      echo "Options:"
      echo "  -e, --editor <cmd>  Specify editor command"
      echo "  -h, --help          Show this help message"
      echo ""
      echo "Automatically uses sudoedit if the file requires root permissions."
      return 0
      ;;
    -e | --editor)
      custom_editor="$2"
      shift 2
      ;;
    *)
      file="$1"
      shift
      ;;
    esac
  done

  if [[ -z "$file" ]]; then
    echo "❌ Error: File argument missing" >&2
    return 1
  fi

  local editor_cmd="${custom_editor:-${EDITOR:-nano}}"

  if [[ -w "$file" || (! -e "$file" && -w "$(dirname "$file")") ]]; then
    $editor_cmd "$file"
  else
    EDITOR="$editor_cmd" sudoedit "$file"
  fi
}

# ==============================================================================
# Nix Development & Package Utilities
# ==============================================================================

nix_pkg_builder() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: nix_pkg_builder [target.nix]"
    return 0
  fi

  local target="${1:-default.nix}"

  if [[ ! -f "$target" ]]; then
    echo "❌ Error: Specify a valid nix expression file (e.g., nix_pkg_builder package.nix)" >&2
    return 1
  fi

  echo "Building package configuration from $target..."
  # Modern Nix 3 replacement for 'nix-build -e ...'
  nix build --file "$target"
}

nix_opt() {
  if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: nix_opt [options.path.here]" >&2
    return 1
  fi
  # Replaced sluggish nix-shell with fast, on-demand modern nix shell execution
  nix shell nixpkgs#nixos-option -c nixos-option "$@"
}

nix_get_attr() {
  local attr_path="$1"
  local nix_file_path="${2:-<nixpkgs>}"

  if [[ "$1" == "-h" || "$1" == "--help" || -z "$attr_path" ]]; then
    echo "Usage: nix_get_attr [attribute.path] [optional_file_path]" >&2
    return 1
  fi

  local expression="with import ${nix_file_path} {}; ${attr_path}"
  nix-instantiate --eval --expr "$expression" --raw
}

nix_hash_prefetch() {
  local url="$1"
  local type="${2:-sha256}"

  if [[ "$1" == "-h" || "$1" == "--help" || -z "$url" ]]; then
    echo "❌ Error: Target URL missing" >&2
    return 1
  fi

  echo "Downloading target asset and generating SRI hashes..." >&2

  local store_hash
  store_hash=$(nix-prefetch-url "$url")

  if [[ -n "$store_hash" ]]; then
    nix-hash --sri --type "$type" "$store_hash"
  fi
}

nix_clean() {
  local user=false system=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      echo "nix_clean - Nix Garbage Collection Helper"
      echo ""
      echo "Usage: nix_clean [options]"
      echo ""
      echo "Options:"
      echo "  -u, --user      Clean user-level garbage"
      echo "  -s, --system    Clean system-level garbage (requires sudo)"
      echo "  -a, --all       Clean both user and system garbage"
      echo "  -h, --help      Show this help message"
      echo ""
      echo "Default: Both user and system garbage are cleaned if no flags are provided."
      return 0
      ;;
    -u | --user)
      user=true
      shift
      ;;
    -s | --system)
      system=true
      shift
      ;;
    -a | --all)
      user=true
      system=true
      shift
      ;;
    *)
      echo "❌ Error: Unknown option '$1'" >&2
      return 1
      ;;
    esac
  done

  if [[ "$user" == false && "$system" == false ]]; then
    user=true
    system=true
  fi

  if [[ "$user" == true ]]; then
    echo "🧹 Cleaning user-level garbage..."
    nix-collect-garbage -d
  fi

  if [[ "$system" == true ]]; then
    echo "🧹 Cleaning system-level garbage (requires sudo)..."
    sudo nix-collect-garbage -d
  fi
}

# ==============================================================================
# Desktop Security & Administration
# ==============================================================================

unlock_keyring() {
  local do_gnome=false do_kwallet=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      echo "unlock_keyring - System Keyring Unlocker"
      echo ""
      echo "Usage: unlock_keyring [options]"
      echo ""
      echo "Options:"
      echo "  -g, --gnome      Unlock GNOME Keyring"
      echo "  -k, --kwallet    Unlock KWallet"
      echo "  -h, --help       Show this help message"
      echo ""
      echo "Default: Auto-detects desktop environment if no flags are provided."
      return 0
      ;;
    -g | --gnome)
      do_gnome=true
      shift
      ;;
    -k | --kwallet)
      do_kwallet=true
      shift
      ;;
    *)
      echo "❌ Error: Unknown option '$1'" >&2
      return 1
      ;;
    esac
  done

  local desktop="${XDG_CURRENT_DESKTOP,,}"
  local success=false

  # Default logic: Use desktop detection if no flags passed
  if [[ "$do_gnome" == false && "$do_kwallet" == false ]]; then
    [[ "$desktop" == *"kde"* || "$desktop" == *"plasma"* ]] && do_kwallet=true
    do_gnome=true
  fi

  # Handle KDE/Plasma Keyrings (KWallet)
  if [[ "$do_kwallet" == true ]] && command -v kwallet-query &> /dev/null; then
    echo "Attempting KWallet access..."
    kwallet-query -l kdewallet > /dev/null 2>&1 && echo "✓ KWallet is active/unlocked." && success=true
  fi

  # Handle GNOME Keyring (also common as a Secret Service backend on KDE)
  if { [[ "$do_gnome" == true ]] || [[ "$success" == false ]]; } && command -v gnome-keyring-daemon &> /dev/null; then
    local pass
    read -rsp "Enter Login Password to Unlock GNOME Keyring: " pass
    echo ""

    local daemon_out
    if daemon_out=$(echo -n "$pass" | gnome-keyring-daemon --replace --unlock 2> /dev/null); then
      eval "export $daemon_out"
      echo "✓ GNOME Security keyring unlocked successfully."
      success=true
    fi
    unset pass
  fi

  if [[ "$success" == false ]]; then
    echo "❌ Error: Failed to unlock a supported keyring (gnome-keyring or kwallet)." >&2
    return 1
  fi
}

process_manager() {
  local action="$1"
  local target="$2"
  local matches

  if [[ "$1" == "-h" || "$1" == "--help" || -z "$action" || -z "$target" ]]; then
    echo "Usage: process_manager [pause|resume|kill|status] [process_name|pid]"
    return 1
  fi

  # Numeric verification ensures exact match captures or broad pattern searches
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    matches="$target"
  else
    matches=$(pgrep -f "$target")
  fi

  if [[ -z "$matches" ]]; then
    echo "❌ Error: No running processes found matching target '$target'." >&2
    return 1
  fi

  echo "Matching process targets discovered:"
  pgrep -fl "$target"

  # Perform interactive validation confirmations before executing volatile signals
  if [[ "$action" == "kill" || "$action" == "pause" ]]; then
    local confirm
    read -p "⚠️ Are you sure you want to execute '$action' on these processes? (y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && echo "Action aborted cleanly." && return 0
  fi

  case "$action" in
  pause)
    echo "$matches" | xargs kill -STOP && echo "✓ Target threads paused."
    ;;
  resume)
    echo "$matches" | xargs kill -CONT && echo "✓ Target threads resumed."
    ;;
  kill)
    # Uses standard SIGTERM first, falls back cleanly
    echo "$matches" | xargs kill -15 && echo "✓ Terminate signals broadcasted."
    ;;
  status)
    echo "Processes are actively registered in kernel tree."
    ;;
  *)
    echo "❌ Error: Action '$action' not recognized." >&2
    return 1
    ;;
  esac
}
