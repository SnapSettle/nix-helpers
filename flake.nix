{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.nixpkgs-fmt.enable = true;
          settings.formatter.shell = {
            command = pkgs.shfmt;
            options = [ "-i" "2" "-sr" "-w" ];
            includes = [ "*.sh" "*.bash" "*.zsh" ];
          };
        };
      in
      {
        formatter = treefmtEval.config.build.wrapper;

        packages.default = pkgs.stdenv.mkDerivation {
          name = "nix-helpers";
          src = ./shell;
          installPhase = ''
            mkdir -p $out/share
            cp helpers.bash $out/share/helpers.bash
          '';
        };
      }
    );
}