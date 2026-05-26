# Nix Helpers

> [!NOTE]
> This project is a part of [SnapCore](https://github.com/SnapSettle/snapcore)!

A collection of streamlined shell utilities for NixOS management, package development, and system administration.

## Features

- **`rbf` (Rebuild Flake)**: A robust wrapper for `nixos-rebuild`. It handles automatic git staging, creates atomic commits with system generation numbers, and provides automatic rollback on failure.
- **Interactive File Finder**: Press `Ctrl+O` to search and open files using `fzf` and `bat`.
- **Nix Development Tools**:
  - `nix_pkg_builder`: Simple wrapper for `nix build`.
  - `nix_opt`: Fast `nixos-option` inspection using `nix shell`.
  - `nix_hash_prefetch`: Generate SRI hashes for remote assets.
  - `nix_get_attr`: Evaluate Nix attributes directly from the CLI.
- **System Management**:
  - `process_manager`: Interactive tool to pause, resume, or kill processes by name or PID.
  - `unlock_keyring`: Command-line utility to unlock GNOME Keyring or KWallet.

## Usage

### NixOS (Recommended)

Add this flake to your system configuration to automatically source the helpers and completions in interactive shells:

```nix
# flake.nix
{
  inputs.nix-helpers.url = "github:snapsettle/nix-helpers";

  outputs = { self, nixpkgs, nix-helpers, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      modules = [
        nix-helpers.nixosModules.default
        # ... your other modules
      ];
    };
  };
}
```

### Manual Installation

If you aren't using the NixOS module, you can source the script directly in your `.bashrc`:

```bash
source /home/$USER/nix-helpers/shell/helpers.bash
```
