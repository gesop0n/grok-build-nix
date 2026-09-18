{
  description = "Nix package for Grok Build - xAI's coding agent harness and TUI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
    }:
    let
      inherit (nixpkgs) lib;

      # Nixpkgs 26.11 dropped x86_64-darwin, so a per-system output for it cannot
      # even evaluate here. The package itself still supports it (see
      # sources.json), so `overlays.default` keeps working on nixpkgs 26.05.
      unsupportedByNixpkgs = [ "x86_64-darwin" ];

      eachSystem =
        f:
        lib.foldl' lib.recursiveUpdate { } (
          map f (lib.subtractLists unsupportedByNixpkgs (import systems))
        );

      overlay = final: prev: {
        grok = final.callPackage ./package.nix { };
      };
    in
    eachSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
      in
      {
        packages.${system} = {
          default = pkgs.grok;
          grok = pkgs.grok;

          # Same binary, additionally linked as `agent` (upstream's alias).
          grok-with-agent-alias = pkgs.grok.override { withAgentAlias = true; };
        };

        apps.${system} = rec {
          default = grok;
          grok = {
            type = "app";
            program = lib.getExe pkgs.grok;
            meta = { inherit (pkgs.grok.meta) description; };
          };
        };

        checks.${system} = {
          inherit (self.packages.${system}) grok;
        };

        devShells.${system}.default = pkgs.mkShell {
          packages = with pkgs; [
            cachix
            jq
            nix-prefetch
            nixfmt
            shellcheck
          ];
        };

        formatter.${system} = pkgs.nixfmt;
      }
    )
    // {
      overlays.default = overlay;
    };
}
