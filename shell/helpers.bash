# ==============================================================================
# NixOS Flake Rebuild Tool
# ==============================================================================
rbf() {
  local actions=() extra_args=() do_update=false hostname=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        echo "rbf - NixOS Flake Rebuild Tool"
        echo ""
        echo "Usage: rbf [action] [options] [-- extra_args]"
        echo ""
        echo "Actions:"
        echo "  boot|switch|test        NixOS rebuild action to perform (default: switch)"
        echo ""
        echo "Options:"
        echo "  -h, --help              Show this help message"
        echo "  --up-all, --update-all  Update all flake inputs before rebuilding"
        echo "  --hostname <name>       Specify a specific hostname configuration from the flake"
        echo ""
        echo "Extra arguments are passed to 'nixos-rebuild'."
        return 0
        ;;
      boot|switch|test) actions+=("$1"); shift ;;
      --up-all|--update-all) do_update=true; shift ;;
      --hostname) hostname="$2"; shift 2 ;;
      *) extra_args+=("$1"); shift ;;
    esac
  done

  [[ ${#actions[@]} -eq 0 ]] && actions+=("switch")

  local config_dir=""
  for dir in "." "/etc/nixos"; do
    if [[ -f "$dir/flake.nix" ]]; then
      config_dir="$dir"; break
    fi
  done

  if [[ -z "$config_dir" ]]; then
    echo "❌ Error: Could not find a NixOS flake directory." >&2
    return 1
  fi

  pushd "$config_dir" > /dev/null || return 1

  local is_git=false
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    is_git=true
    git add .
  else
    echo "Not a git repository. Continuing anyway.."
  fi

  if [[ "$do_update" == true ]]; then
    echo "Updating all flake inputs..."
    nix flake update
    [[ "$is_git" == true ]] && git add flake.lock
  fi

  local real_user=${SUDO_USER:-$USER}
  local git_env_flags=(-c "user.name=$real_user" -c "user.email=$real_user@$(hostname)")

  if [[ "$is_git" == true ]] && ! git diff --cached --quiet; then
    local files=$(git diff --cached --name-only | paste -sd "," -)
    local msg="Pre-rebuild (${actions[*]}): $files"
    echo "Committing changes: $msg"
    git "${git_env_flags[@]}" commit -m "$msg" >/dev/null
  fi

  local success=true flake_path="."
  [[ -n "$hostname" ]] && flake_path=".#$hostname"

  for action in "${actions[@]}"; do
    echo "Executing NixOS $action..."
    sudo nixos-rebuild "$action" --flake "$flake_path" "${extra_args[@]}" || { success=false; break; }
  done

  if [[ "$success" == true ]]; then
    if [[ "$is_git" == true ]]; then
      local target_link=$(readlink /nix/var/nix/profiles/system)
      local gen="?"
      [[ "$target_link" =~ system-([0-9]+)-link ]] && gen="${BASH_REMATCH[1]}"
      git "${git_env_flags[@]}" commit --amend -m "Gen $gen (${actions[*]}): finalized" >/dev/null 2>&1
      echo "✓ Rebuild successful. Generation $gen is now active."
    else
      echo "✓ Rebuild successful (No Git history to update)."
    fi
  else
    echo "❌ Rebuild failed."
    if [[ "$is_git" == true && $(git log -1 --pretty=%s) == Pre-rebuild* ]]; then
      echo "Rolling back temporary Git commit..."
      git reset --soft HEAD~1
    fi
  fi

  popd > /dev/null || return 1
  [[ "$success" == true ]]
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
  if command -v bat &>/dev/null; then
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
      -h|--help)
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
      -e|--editor) custom_editor="$2"; shift 2 ;;
      *) file="$1"; shift ;;
    esac
  done

  if [[ -z "$file" ]]; then
    echo "❌ Error: File argument missing" >&2
    return 1
  fi

  local editor_cmd="${custom_editor:-${EDITOR:-nano}}"

  if [[ -w "$file" || ( ! -e "$file" && -w "$(dirname "$file")" ) ]]; then
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
      -h|--help)
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
      -u|--user) user=true; shift ;;
      -s|--system) system=true; shift ;;
      -a|--all) user=true; system=true; shift ;;
      *) echo "❌ Error: Unknown option '$1'" >&2; return 1 ;;
    esac
  done

  if [[ "$user" == false && "$system" == false ]]; then
    user=true; system=true
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
      -h|--help)
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
      -g|--gnome) do_gnome=true; shift ;;
      -k|--kwallet) do_kwallet=true; shift ;;
      *) echo "❌ Error: Unknown option '$1'" >&2; return 1 ;;
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
  if [[ "$do_kwallet" == true ]] && command -v kwallet-query &>/dev/null; then
    echo "Attempting KWallet access..."
    kwallet-query -l kdewallet >/dev/null 2>&1 && echo "✓ KWallet is active/unlocked." && success=true
  fi

  # Handle GNOME Keyring (also common as a Secret Service backend on KDE)
  if { [[ "$do_gnome" == true ]] || [[ "$success" == false ]]; } && command -v gnome-keyring-daemon &>/dev/null; then
    local pass
    read -rsp "Enter Login Password to Unlock GNOME Keyring: " pass
    echo ""

    local daemon_out
    if daemon_out=$(echo -n "$pass" | gnome-keyring-daemon --replace --unlock 2>/dev/null); then
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