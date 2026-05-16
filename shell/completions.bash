# --------------------------------------------------
# Generic helper
# --------------------------------------------------

__complete_words() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  COMPREPLY=(
    $(compgen -W "$*" -- "$cur")
  )
}

# --------------------------------------------------
# rbf
# --------------------------------------------------

_rbf_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  local suggestions=(
    boot
    switch
    test
    --up
    --update
    --show-trace
    --verbose
    --impure
    --dry-run
    --fast
    --option
  )

  COMPREPLY=(
    $(compgen -W "${suggestions[*]}" -- "$cur")
  )
}

complete -F _rbf_completion rbf

# --------------------------------------------------
# nix_pkg_builder
# --------------------------------------------------

_nix_pkg_builder_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  COMPREPLY=(
    $(compgen -f -X '!*.nix' -- "$cur")
  )
}

complete -F _nix_pkg_builder_completion nix_pkg_builder

# --------------------------------------------------
# nix_opt
# --------------------------------------------------

_nix_opt_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  local suggestions=(
    services.xserver.enable
    networking.hostName
    users.users
    environment.systemPackages
    boot.loader.systemd-boot.enable
    hardware.opengl.enable
    nix.settings.experimental-features
  )

  COMPREPLY=(
    $(compgen -W "${suggestions[*]}" -- "$cur")
  )
}

complete -F _nix_opt_completion nix_opt

# --------------------------------------------------
# nix_get_attr
# --------------------------------------------------

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
    lib.lists
  )

  COMPREPLY=(
    $(compgen -W "${suggestions[*]}" -- "$cur")
  )
}

complete -F _nix_get_attr_completion nix_get_attr

# --------------------------------------------------
# nix_hash_prefetch
# --------------------------------------------------

_nix_hash_prefetch_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ $COMP_CWORD -eq 2 ]]; then
    COMPREPLY=(
      $(compgen -W "sha1 sha256 sha512" -- "$cur")
    )
    return
  fi

  COMPREPLY=()
}

complete -F _nix_hash_prefetch_completion nix_hash_prefetch

# --------------------------------------------------
# process_manager
# --------------------------------------------------

_process_manager_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=(
      $(compgen -W "pause resume kill status" -- "$cur")
    )
    return
  fi

  # Complete running process names
  local processes
  processes=$(ps -eo comm= | sort -u)

  COMPREPLY=(
    $(compgen -W "$processes" -- "$cur")
  )
}

complete -F _process_manager_completion process_manager

# --------------------------------------------------
# unlock-keyring
# --------------------------------------------------

_unlock_keyring_completion() {
  COMPREPLY=()
}

complete -F _unlock_keyring_completion unlock-keyring

# --------------------------------------------------
# fzf-open-editor
# --------------------------------------------------

_fzf_open_editor_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"

  COMPREPLY=(
    $(compgen -f -- "$cur")
  )
}

complete -F _fzf_open_editor_completion fzf-open-editor
