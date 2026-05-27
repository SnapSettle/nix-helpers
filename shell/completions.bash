# ==============================================================================
# Generic Completion Helper Utilities
# ==============================================================================

__complete_words() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=($(compgen -W "$*" -- "$cur"))
}

# ==============================================================================
# NixOS Flake Rebuild Tool Completions (rbf)
# ==============================================================================

_rbf_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local suggestions=(
    boot
    switch
    test
    --help
    --up
    --update-all
    --up-only
    --update-only
    --fmt
    --format
    --hostname
    --show-trace
    --verbose
    --impure
    --dry-run
    --fast
    --option
  )

  COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))
}
complete -F _rbf_completion rbf

# ==============================================================================
# Interactive File Finder & Editor Completions
# ==============================================================================

_fzf_open_editor_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "-h --help" -- "$cur"))
  else
    COMPREPLY=($(compgen -f -- "$cur"))
  fi
}
complete -F _fzf_open_editor_completion fzf-open-editor

_e_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [[ "$prev" == "-e" || "$prev" == "--editor" ]]; then
    COMPREPLY=($(compgen -c -- "$cur"))
    return
  fi

  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "-h --help -e --editor" -- "$cur"))
  else
    COMPREPLY=($(compgen -f -- "$cur"))
  fi
}
complete -F _e_completion e

# ==============================================================================
# Nix Development & Package Utilities Completions
# ==============================================================================

_nix_pkg_builder_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "-h --help" -- "$cur"))
  else
    # Only match files matching *.nix extension patterns natively
    COMPREPLY=($(compgen -f -X '!*.nix' -- "$cur"))
  fi
}
complete -F _nix_pkg_builder_completion nix_pkg_builder

_nix_opt_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local suggestions=(
    services.xserver.enable
    networking.hostName
    users.users
    environment.systemPackages
    boot.loader.systemd-boot.enable
    hardware.graphics.enable
    nix.settings.experimental-features
    --help
    -h
  )

  COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))
}
complete -F _nix_opt_completion nix_opt

_nix_get_attr_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local suggestions=(
    pkgs.firefox
    pkgs.neovim
    pkgs.git
    pkgs.vim
    pkgs.hello
    lib.attrsets
    lib.strings
    --help
    -h
    lib.lists
  )

  COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))
}
complete -F _nix_get_attr_completion nix_get_attr

_nix_hash_prefetch_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "-h --help" -- "$cur"))
    return
  fi

  # Check position safely to prevent argument leakage downstream
  if [[ "$COMP_CWORD" -eq 2 ]]; then
    COMPREPLY=($(compgen -W "sha1 sha256 sha512" -- "$cur"))
    return
  fi

  COMPREPLY=()
}
complete -F _nix_hash_prefetch_completion nix_hash_prefetch

_nix_clean_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local suggestions=(--user --system --all --help -u -s -a -h)
  COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))
}
complete -F _nix_clean_completion nix_clean

# ==============================================================================
# Desktop Security & Administration Completions
# ==============================================================================

_process_manager_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "pause resume kill status --help -h" -- "$cur"))
    return
  fi

  # Safely parse running tasks into memory arrays avoiding subshell pipelines
  local processes
  mapfile -t processes < <(ps -eo comm= | sort -u)
  COMPREPLY=($(compgen -W "${processes[*]}" -- "$cur"))
}
complete -F _process_manager_completion process_manager

_unlock_keyring_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local suggestions=(--help -h --gnome --kwallet -g -k)
  COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))
}
complete -F _unlock_keyring_completion unlock_keyring