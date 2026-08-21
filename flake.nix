{
  description = "AgentProlog standalone coding-agent product";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    prolog-rlm = {
      url = "github:lost-rob0t/prolog-rlm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        upstream = prolog-rlm.packages.${system}.default;
        agentProlog = pkgs.writeShellApplication {
          name = "agentProlog";
          runtimeInputs = [ pkgs.swiProlog upstream ];
          text = ''
            exec swipl -q -g "use_module(library(rlm)),writeln('AgentProlog runtime ready'),halt" -- "$@"
          '';
        };
      in {
        packages.agentProlog = agentProlog;
        packages.default = agentProlog;

        apps.agentProlog = flake-utils.lib.mkApp { drv = agentProlog; };
        apps.default = self.apps.${system}.agentProlog;

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.swiProlog upstream ];
        };

        checks.runtime-load = pkgs.runCommand "agentprolog-runtime-load" {
          nativeBuildInputs = [ pkgs.swiProlog upstream ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cd "$TMPDIR"
          swipl -q -g "use_module(library(rlm)),halt"
          touch "$out"
        '';

        checks.default-app = pkgs.runCommand "agentprolog-default-app" {
          nativeBuildInputs = [ agentProlog ];
        } ''
          agentProlog | grep -F "AgentProlog runtime ready"
          touch "$out"
        '';
      });
}
