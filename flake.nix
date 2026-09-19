{
  description = "AgentProlog standalone coding-agent product";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    prolog-rlm = {
      # Zara runtime profile integration pins the merged upstream
      # prolog-rlm#448 main commit; AgentProlog remains downstream and must
      # not fork or redefine the generic runtime ABI.
      url = "github:lost-rob0t/prolog-rlm/fa03bb5b48c858b16ec6061d5b49804ee6f29070";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        upstream = prolog-rlm.packages.${system}.default;
        upstreamSwipl = "${upstream}/bin/prolog-rlm-swipl";
        agentProlog = pkgs.writeShellApplication {
          name = "agentProlog";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstreamSwipl} -q -g "use_module(library(rlm)),writeln('AgentProlog runtime ready'),halt" -- "$@"
          '';
        };
        agentPrologZaraRuntime = pkgs.writeShellApplication {
          name = "agentprolog-zara-runtime";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstream}/bin/prolog-rlm-zara --profile agentprolog "$@"
          '';
        };
      in {
        packages.agentProlog = agentProlog;
        packages.agentProlog-zara-runtime = agentPrologZaraRuntime;
        packages.default = agentProlog;

        apps.agentProlog = flake-utils.lib.mkApp { drv = agentProlog; };
        apps.zara-runtime = flake-utils.lib.mkApp { drv = agentPrologZaraRuntime; };
        apps.default = self.apps.${system}.agentProlog;

        devShells.default = pkgs.mkShell {
          packages = [ upstream pkgs.nodejs ];
        };

        checks.workbench-client = pkgs.runCommand "agentprolog-workbench-client" {
          nativeBuildInputs = [ pkgs.nodejs ];
          PROLOG_RLM_SOURCE = prolog-rlm.outPath;
        } ''
          cd ${self.outPath}
          node --test packages/workbench-client/test
          touch "$out"
        '';

        checks.runtime-load = pkgs.runCommand "agentprolog-runtime-load" {
          nativeBuildInputs = [ upstream ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cd "$TMPDIR"
          ${upstreamSwipl} -q -g "use_module(library(rlm)),halt"
          touch "$out"
        '';

        checks.default-app = pkgs.runCommand "agentprolog-default-app" {
          nativeBuildInputs = [ agentProlog ];
        } ''
          agentProlog | grep -F "AgentProlog runtime ready"
          touch "$out"
        '';

        checks.zara-runtime-profile = pkgs.runCommand "agentprolog-zara-runtime-profile" {
          nativeBuildInputs = [ upstream agentPrologZaraRuntime ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          prolog-rlm-swipl -q -g "use_module(library(rlm_zara_runtime)),rlm_zara_runtime:zara_runtime_set_profiles([agentprolog]),rlm_zara_runtime:zara_runtime_descriptor(D),get_dict(id,D,\"prolog-rlm\"),get_dict(profiles,D,[\"agentprolog\"]),halt"
          agentprolog-zara-runtime --help 2>&1 | grep -F "Usage: prolog-rlm-zara"
          touch "$out"
        '';
      });
}
