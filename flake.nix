{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix }:
    let
      systems = flake-utils.lib.defaultSystems;
    in
    {
      nixosModules.default = { pkgs, ... }: {
        programs.bash.interactiveShellInit = ''
          if [[ -f ${self.packages.${pkgs.system}.default}/share/nix-helpers/helpers.bash ]]; then
            source ${self.packages.${pkgs.system}.default}/share/nix-helpers/helpers.bash
          fi

          if [[ -f ${self.packages.${pkgs.system}.default}/share/nix-helpers/completions.bash ]]; then
            source ${self.packages.${pkgs.system}.default}/share/nix-helpers/completions.bash
          fi
        '';
      };

    } // flake-utils.lib.eachSystem systems (system:
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
          pname = "nix-helpers";
          version = "0.1.0";

          src = ./shell;

          installPhase = ''
            mkdir -p $out/share/nix-helpers

            if [[ -f helpers.bash ]]; then
              cp helpers.bash $out/share/nix-helpers/helpers.bash
            fi

            if [[ -f completions.bash ]]; then
              cp completions.bash $out/share/nix-helpers/completions.bash
            fi
          '';
        };
      });
}
