rbf() {
  local actions=()
  local extra_args=()

  local do_update=false
  local update_target=""

  local expect_update_target=false

  for arg in "$@"; do
    case "$arg" in
    boot | switch | test)
      actions+=("$arg")
      ;;

    --up | --update)
      do_update=true
      expect_update_target=true
      ;;

    *)
      if [[ "$expect_update_target" == true && "$arg" != --* ]]; then
        update_target="$arg"
        expect_update_target=false
      else
        extra_args+=("$arg")
      fi
      ;;
    esac
  done

  [[ ${#actions[@]} -eq 0 ]] && actions+=("switch")

  if [[ -d "/etc/nixos" ]]; then
    pushd /etc/nixos > /dev/null || return 1
  else
    echo "Error: /etc/nixos not found." >&2
    return 1
  fi

  local is_git=false

  if [[ -d ".git" ]]; then
    is_git=true

    sudo git add .
    sudo git update-index -q --refresh
  fi

  # --------------------------------------------------
  # Flake updates
  # --------------------------------------------------

  if [[ "$do_update" == true ]]; then
    if [[ -n "$update_target" ]]; then
      echo "Updating flake input: $update_target"
      sudo nix flake lock --update-input "$update_target"
    else
      echo "Updating all flake inputs..."
      sudo nix flake update
    fi

    [[ "$is_git" == true ]] && sudo git add flake.lock
  fi

  # --------------------------------------------------
  # Git pre-rebuild commit
  # --------------------------------------------------

  if [[ "$is_git" == true ]] && ! sudo git diff --cached --quiet; then
    local real_user=${SUDO_USER:-$USER}
    local real_host
    real_host=$(hostname)

    local files
    files=$(sudo git diff --cached --name-only |
      tr '\n' ',' |
      sed 's/,$//' |
      sed 's/,/, /g')

    local msg="Pre-rebuild (${actions[*]}): $files"

    echo "Committing changes: $msg"

    sudo git \
      -c "user.name=$real_user" \
      -c "user.email=$real_user@$real_host" \
      commit -m "$msg"
  fi

  # --------------------------------------------------
  # Rebuild
  # --------------------------------------------------

  local success=true

  for action in "${actions[@]}"; do
    echo "Executing NixOS $action..."

    if ! sudo nixos-rebuild "$action" --flake . "${extra_args[@]}"; then
      success=false
      break
    fi
  done

  # --------------------------------------------------
  # Post rebuild
  # --------------------------------------------------

  if [[ "$success" == true ]]; then
    if [[ "$is_git" == true ]]; then
      local gen

      gen=$(sudo nixos-rebuild list-generations --flake . 2> /dev/null |
        awk '$NF == "True" { print $1 }')

      local real_user=${SUDO_USER:-$USER}

      local real_host
      real_host=$(hostname)

      sudo git \
        -c "user.name=$real_user" \
        -c "user.email=$real_user@$real_host" \
        commit --amend \
        -m "Gen $gen (${actions[*]}): finalized" \
        > /dev/null 2>&1

      echo "Rebuild successful. Generation $gen active."
    else
      echo "Rebuild successful (No Git history to update)."
    fi

    popd > /dev/null || true
    return 0
  else
    echo "Rebuild failed."

    popd > /dev/null || true
    return 1
  fi
}

fzf-open-editor() {
  local file
  file=$(fzf --preview 'bat --style=numbers --color=always --line-range :500 {}' 2> /dev/null)

  if [[ -n $file ]]; then
    ${EDITOR:-nano} "$file"
  fi

  # Terminal cursor reset
  bind '"\e[0n": ""'
  printf '\e[5n'
}

# Bind Ctrl+O to the fzf editor function
bind -x '"\C-o": fzf-open-editor'

# 3. Nix Package Builder
nix_pkg_builder() {
  if [[ -f $1 ]]; then
    nix-build -e "with import <nixpkgs> {}; callPackage $1 {}"
    rbf() {
      for arg in "$@"; do
        case "$arg" in
        boot | switch)
          echo "Processing: $arg"
          if [ -d "/etc/nixos" ]; then
            pushd /etc/nixos > /dev/null || return 1
            sudo nixos-rebuild "$arg"
            popd > /dev/null || return 1
          else
            echo "Error: /etc/nixos directory not found!" >&2
            return 1
          fi
          ;;
        *)
          echo "Error: Invalid argument '$arg'. Use 'boot' or 'switch'." >&2
          return 1
          ;;
        esac
      done
    }

    fzf-open-editor() {
      # Fixed the ''${EDITOR} Nix escape to standard Bash ${EDITOR}
      local file
      file=$(fzf --preview 'bat --style=numbers --color=always --line-range :500 {}' 2> /dev/null)

      if [[ -n $file ]]; then
        ${EDITOR:-nano} "$file"
      fi

      # Terminal cursor reset
      bind '"\e[0n": ""'
      printf '\e[5n'
    }

    # Bind Ctrl+O to the fzf editor function
    bind -x '"\C-o": fzf-open-editor'

    # Nix Package Builder
    nix_pkg_builder() {
      if [[ -f $1 ]]; then
        nix-build -e "with import <nixpkgs> {}; callPackage $1 {}"
      else
        echo 'Error: No file specified'
      fi
    }

    # Nix Option Explorer
    nix_opt() {
      nix-shell -p nixos-option --run "nixos-option $*"
    }

    # Get Nix Attribute
    nix_get_attr() {
      local attr_path="$1"
      local nix_file_path="${2:-<nixpkgs>}" # Fixed Nix escapes

      local expression="with import ${nix_file_path} {}; ${attr_path}"
      nix-instantiate --eval --expr "$expression" --raw
    }

    # Nix Hash Prefetch (Fixed parameter expansion)
    nix_hash_prefetch() {
      local url="$1"
      local type="${2:-sha256}" # Fixed the syntax here

      if [[ -z $url ]]; then
        echo "Error: URL missing"
        return 1
      fi

      echo "Fetching and hashing..." >&2

      local store_hash
      store_hash=$(nix-prefetch-url "$url")

      if [[ -n $store_hash ]]; then
        nix-hash --sri --type "$type" "$store_hash"
      fi
    }

    # Unlock Keyring
    unlock-keyring() {
      local pass
      read -rsp "Password: " pass
      echo ""
      # Ensure gnome-keyring-daemon is available
      export $(echo -n "$pass" | gnome-keyring-daemon --replace --unlock)
      unset pass
    }

    # Process Manager
    process_manager() {
      local action="$1"
      local target="$2"
      local matches

      if [[ -z $action || -z $target ]]; then
        echo "Usage: process_manager [pause|resume|kill|status] [name_or_pid]"
        return 1
      fi

      # Check if target is a pid or a name
      if [[ $target =~ ^[0-9]+$ ]]; then
        matches="$target"
      else
        matches=$(pgrep -f "$target")
      fi

      if [[ -z $matches ]]; then
        echo "Error: No process found matching '$target'."
        return 1
      fi

      echo "Found the following matches:"
      pgrep -fl "$target"

      # Safety check
      if [[ $action == "kill" || $action == "pause" ]]; then
        read -p "Apply $action to these processes? (y/n): " confirm
        [[ $confirm != "y" ]] && echo "Action cancelled." && return 0
      fi

      case "$action" in
      pause) kill -STOP $matches && echo "Paused." ;;
      resume) kill -CONT $matches && echo "Resumed." ;;
      kill) kill -9 $matches && echo "Killed." ;;
      status) echo "Processes are running." ;;
      *) echo "Invalid action." ;;
      esac
    }
  else
    echo 'Error: No file specified'
  fi
}

# 4. Nix Option Explorer
nix_opt() {
  nix-shell -p nixos-option --run "nixos-option $*"
}

# 5. Get Nix Attribute
nix_get_attr() {
  local attr_path="$1"
  local nix_file_path="${2:-<nixpkgs>}" # Fixed Nix escapes

  local expression="with import ${nix_file_path} {}; ${attr_path}"
  nix-instantiate --eval --expr "$expression" --raw
}

# 6. Nix Hash Prefetch (Fixed parameter expansion)
nix_hash_prefetch() {
  local url="$1"
  local type="${2:-sha256}" # Fixed the syntax here

  if [[ -z $url ]]; then
    echo "Error: URL missing"
    return 1
  fi

  echo "Fetching and hashing..." >&2

  local store_hash
  store_hash=$(nix-prefetch-url "$url")

  if [[ -n $store_hash ]]; then
    nix-hash --sri --type "$type" "$store_hash"
  fi
}

# 7. Unlock Keyring
unlock-keyring() {
  local pass
  read -rsp "Password: " pass
  echo ""
  # Ensure gnome-keyring-daemon is available
  export $(echo -n "$pass" | gnome-keyring-daemon --replace --unlock)
  unset pass
}

# 8. Process Manager
process_manager() {
  local action="$1"
  local target="$2"
  local matches

  if [[ -z $action || -z $target ]]; then
    echo "Usage: process_manager [pause|resume|kill|status] [name_or_pid]"
    return 1
  fi

  # Check if target is a pid or a name
  if [[ $target =~ ^[0-9]+$ ]]; then
    matches="$target"
  else
    matches=$(pgrep -f "$target")
  fi

  if [[ -z $matches ]]; then
    echo "Error: No process found matching '$target'."
    return 1
  fi

  echo "Found the following matches:"
  pgrep -fl "$target"

  # Safety check
  if [[ $action == "kill" || $action == "pause" ]]; then
    read -p "Apply $action to these processes? (y/n): " confirm
    [[ $confirm != "y" ]] && echo "Action cancelled." && return 0
  fi

  case "$action" in
  pause) kill -STOP $matches && echo "Paused." ;;
  resume) kill -CONT $matches && echo "Resumed." ;;
  kill) kill -9 $matches && echo "Killed." ;;
  status) echo "Processes are running." ;;
  *) echo "Invalid action." ;;
  esac
}
