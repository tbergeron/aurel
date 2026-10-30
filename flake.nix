{
  description = "Aurel: macOS voice and AI assistant";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-darwin-legacy.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-darwin-legacy,
    }:
    let
      version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./VERSION);
      targetSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forEachSystem =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) targetSystems
        );
      pkgsFor =
        system:
        if system == "x86_64-darwin" then
          nixpkgs-darwin-legacy.legacyPackages.${system}
        else
          nixpkgs.legacyPackages.${system};
      packageFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellApplication {
          name = "aurel";
          runtimeInputs = [ pkgs.python313 ];
          text = ''
            set -euo pipefail
            src=${./.}
            case "''${1:-}" in
              ""|install|--install|build|--build)
                exec bash "$src/build.sh"
                ;;
              --check)
                python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$src/aurel.py"
                bash -n "$src/build.sh"
                bash -n "$src/install.sh"
                printf '%s\n' 'aurel source checks passed'
                ;;
              --version)
                printf '%s\n' "aurel ${version}"
                ;;
              --help|-h|help)
                cat <<'EOF'
            Aurel launcher for macOS.

            Usage:
              aurel              Install or update Aurel.app
              aurel --install    Install or update Aurel.app
              aurel --check      Run packaged source checks
              aurel --version    Print the packaged version
              aurel --help       Show this help

            Building requires macOS 26 or later and Apple's command line tools.
            EOF
                ;;
              *)
                printf 'Unknown option: %s\n\n' "$1" >&2
                exec "$0" --help
                ;;
            esac
          '';
          meta = with pkgs.lib; {
            description = "Aurel macOS app launcher";
            homepage = "https://github.com/tbergeron/aurel";
            license = licenses.mit;
            mainProgram = "aurel";
            platforms = targetSystems;
          };
        };
    in
    {
      packages = forEachSystem (
        system:
        let
          aurel = packageFor system;
        in
        {
          inherit aurel;
          aurel-mac = aurel;
          source = aurel;
          default = aurel;
        }
      );

      apps = forEachSystem (
        system:
        let
          aurel = self.packages.${system}.default;
          program = "${aurel}/bin/aurel";
          app = {
            type = "app";
            inherit program;
            inherit (aurel) meta;
          };
        in
        {
          aurel = app;
          aurel-mac = app;
          default = app;
        }
      );

      checks = forEachSystem (system: {
        package = self.packages.${system}.default;
      });

      devShells = forEachSystem (system: {
        default =
          let
            pkgs = pkgsFor system;
          in
          pkgs.mkShell {
            packages = [
              pkgs.python313
              pkgs.act
            ];
            shellHook = ''
              echo "Aurel development shell. Building the app requires Apple's command line tools."
            '';
          };
      });

      formatter = forEachSystem (system: (pkgsFor system).nixfmt);
    };
}
