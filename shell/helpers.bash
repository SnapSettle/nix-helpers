# ==============================================================================
# NixOS Flake Rebuild Tool
# ==============================================================================
rbf() {
  local actions=()
  local extra_args=()
  local do_update=false

  # Parse command-line flags and identify actions versus raw builder parameters
  for arg in "$@"; do
    case "$arg" in
      boot|switch|test)
        actions+=("$arg")
        ;;
      --up|--update)
        do_update=true
        ;;
      *)
        extra_args+=("$arg")
        ;;
    esac
  done

  # Default to standard switch behavior if no action was explicitly requested
  [[ ${#actions[@]} -eq 0 ]] && actions+=("switch")

  # Locate the NixOS flake context, prioritizing local files then your home directory
  local config_dir=""
  if [[ -f "./flake.nix" ]]; then
    config_dir="."
  elif [[ -d "$HOME/nixos-config" && -f "$HOME/nixos-config/flake.nix" ]]; then
    config_dir="$HOME/nixos-config"
  elif [[ -d "/etc/nixos" && -f "/etc/nixos/flake.nix" ]]; then
    config_dir="/etc/nixos"
  else
    echo "❌ Error: Could not find a NixOS flake directory." >&2
    return 1
  fi

  pushd "$config_dir" > /dev/null || return 1

  # Handle repository staging without root mutation to protect home directory ownership
  local is_git=false
  if [[ -d ".git" || $(git rev-parse --is-inside-work-tree 2>/dev/null) == "true" ]]; then
    is_git=true
    git add .
    git update-index -q --refresh
  fi

  # Run full block locked dependency upgrades if explicitly triggered
  if [[ "$do_update" == true ]]; then
    echo "Updating all flake inputs..."
    nix flake update
    [[ "$is_git" == true ]] && git add flake.lock
  fi

  # Establish Git environment identities mapping to the non-root execution user
  local real_user=${SUDO_USER:-$USER}
  local real_host=$(hostname)
  local git_env_flags=(-c "user.name=$real_user" -c "user.email=$real_user@$real_host")

  # Create an atomic, structural checkpoint commit tracking what changed files are being built
  if [[ "$is_git" == true ]] && ! git diff --cached --quiet; then
    local files
    mapfile -t changed_files < <(git diff --cached --name-only)
    IFS=', ' read -r -a joined_files <<< "${changed_files[*]}"
    files="${joined_files[*]}"

    local msg="Pre-rebuild (${actions[*]}): $files"
    echo "Committing changes: $msg"
    git "${git_env_flags[@]}" commit -m "$msg" >/dev/null
  fi

  # Execute the system target deployments sequentially through sudo
  local success=true
  for action in "${actions[@]}"; do
    echo "Executing NixOS $action..."
    if ! sudo nixos-rebuild "$action" --flake . "${extra_args[@]}"; then
      success=false
      break
    fi
  done

  # Process evaluation outcomes, sealing the versioning commit or cleanly rolling back
  if [[ "$success" == true ]]; then
    if [[ "$is_git" == true ]]; then
      # Query the current active system generation profile directly from the kernel symlink
      local target_link
      target_link=$(readlink /nix/var/nix/profiles/system)
      
      local gen
      if [[ "$target_link" =~ system-([0-8]*) ]]; then
        gen="${BASH_REMATCH[1]}"
      else
        gen=$(echo "$target_link" | awk -F'-' '{print $2}')
      fi

      git "${git_env_flags[@]}" commit --amend \
        -m "Gen ${gen:-?} (${actions[*]}): finalized" \
        >/dev/null 2>&1

      echo "✓ Rebuild successful. Generation ${gen:-unknown} is now active."
    else
      echo "✓ Rebuild successful (No Git history to update)."
    fi
    popd > /dev/null || true
    return 0
  else
    echo "❌ Rebuild failed."
    if [[ "$is_git" == true && $(git log -1 --pretty=%s) == Pre-rebuild* ]]; then
      echo "Rolling back temporary Git commit..."
      git reset --soft HEAD~1
    fi
    popd > /dev/null || true
    return 1
  fi
}

# ==============================================================================
# Interactive File Finder & Editor
# ==============================================================================
fzf-open-editor() {
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

# Bind Ctrl+O to instantly trigger the interactive editor window
bind -x '"\C-o": fzf-open-editor'

# ==============================================================================
# Nix Development & Package Utilities
# ==============================================================================

nix_pkg_builder() {
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
  if [[ -z "$1" ]]; then
    echo "Usage: nix_opt [options.path.here]" >&2
    return 1
  fi
  # Replaced sluggish nix-shell with fast, on-demand modern nix shell execution
  nix shell nixpkgs#nixos-option -c nixos-option "$@"
}

nix_get_attr() {
  local attr_path="$1"
  local nix_file_path="${2:-<nixpkgs>}"

  if [[ -z "$attr_path" ]]; then
    echo "Usage: nix_get_attr [attribute.path] [optional_file_path]" >&2
    return 1
  fi

  local expression="with import ${nix_file_path} {}; ${attr_path}"
  nix-instantiate --eval --expr "$expression" --raw
}

nix_hash_prefetch() {
  local url="$1"
  local type="${2:-sha256}"

  if [[ -z "$url" ]]; then
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

# ==============================================================================
# Desktop Security & Administration
# ==============================================================================

unlock-keyring() {
  if ! command -v gnome-keyring-daemon &>/dev/null; then
    echo "❌ Error: gnome-keyring-daemon is not installed on this system." >&2
    return 1
  fi

  local pass
  read -rsp "Enter Login Password to Unlock Keyring: " pass
  echo ""

  # Gracefully export environment variables returned from daemon initialization
  local daemon_out
  if daemon_out=$(echo -n "$pass" | gnome-keyring-daemon --replace --unlock 2>/dev/null); then
    eval "export $daemon_out"
    echo "✓ Security keyring unlocked successfully."
  else
    echo "❌ Error: Failed to unlock keyring daemon." >&2
  fi
  unset pass
}

process_manager() {
  local action="$1"
  local target="$2"
  local matches

  if [[ -z "$action" || -z "$target" ]]; then
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