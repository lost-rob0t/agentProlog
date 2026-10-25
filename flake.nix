{
  description = "AgentProlog standalone coding-agent product";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    prolog-rlm = {
      # Coordinated native session pin. Canonical UI v1 files are byte-identical
      # to the previous pin; execution remains in the reusable upstream runtime.
      url = "github:lost-rob0t/prolog-rlm/086cf8bfa66dd58e5c8aa20ad5716b6bc67712a7";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        upstream = prolog-rlm.packages.${system}.default;
        upstreamSwipl = "${upstream}/bin/prolog-rlm-swipl";
        sessionHost = pkgs.writeShellApplication {
          name = "agentprolog-session";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstreamSwipl} -q -s ${./prolog}/agentprolog_session.pl -- "$@"
          '';
        };
        agentProlog = pkgs.writeShellApplication {
          name = "agentProlog";
          runtimeInputs = [ pkgs.nodejs_22 sessionHost ];
          text = ''
            export AGENTPROLOG_SESSION=${sessionHost}/bin/agentprolog-session
            exec ${pkgs.nodejs_22}/bin/node ${./packages/conversation-ui/src}/cli.js "$@"
          '';
        };
        conversationUi = agentProlog;
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
        packages.conversation-ui = conversationUi;
        packages.session-host = sessionHost;

        apps.agentProlog = flake-utils.lib.mkApp { drv = agentProlog; };
        apps.zara-runtime = flake-utils.lib.mkApp { drv = agentPrologZaraRuntime; };
        apps.default = self.apps.${system}.agentProlog;
        apps.conversation = flake-utils.lib.mkApp { drv = conversationUi; };

        devShells.default = pkgs.mkShell {
          packages = [ upstream pkgs.nodejs_22 ];
        };

        checks.conversation-cli = pkgs.runCommand "agentprolog-conversation-cli" {
          nativeBuildInputs = [ conversationUi ];
        } ''
          agentProlog --help | grep -F "canonical conversation UI"
          touch "$out"
        '';

        checks.generic-native = pkgs.runCommand "agentprolog-generic-native" {
          nativeBuildInputs = [ upstream ];
        } ''
          ${upstreamSwipl} -q \
            -s ${self}/test/agentprolog_config_test.pl \
            -s ${self}/test/agentprolog_session_test.pl \
            -s ${self}/test/agentprolog_workspace_tools_test.pl -g "run_tests,halt"
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
          agentProlog --help | grep -F "canonical conversation UI"
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
