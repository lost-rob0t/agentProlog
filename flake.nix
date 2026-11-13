{
  description = "AgentProlog standalone coding-agent product";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    prolog-rlm = {
      # Coordinated integration candidate: canonical UI v1, validated snapshots,
      # supported MCP execution APIs and the upstream Z.AI coding provider.
      url = "github:lost-rob0t/prolog-rlm/4716ba8aa0bbf3fa1b96d80e8ed8e91d99973c85";
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
            exec ${upstreamSwipl} -q -p library=${./prolog} -s ${./prolog}/agentprolog_session.pl -- "$@"
          '';
        };
        importSkill = pkgs.writeShellApplication {
          name = "agentprolog-import-skill";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstreamSwipl} -q -s ${./prolog}/agentprolog_import_skill.pl -- "$@"
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
        packages.import-skill = importSkill;

        apps.agentProlog = flake-utils.lib.mkApp { drv = agentProlog; };
        apps.zara-runtime = flake-utils.lib.mkApp { drv = agentPrologZaraRuntime; };
        apps.default = self.apps.${system}.agentProlog;
        apps.conversation = flake-utils.lib.mkApp { drv = conversationUi; };
        apps.import-skill = flake-utils.lib.mkApp { drv = importSkill; };

        devShells.default = pkgs.mkShell {
          packages = [ upstream pkgs.nodejs_22 pkgs.python3 importSkill ];
        };

        checks.conversation-cli = pkgs.runCommand "agentprolog-conversation-cli" {
          nativeBuildInputs = [ conversationUi ];
        } ''
          agentProlog --help | grep -F "canonical conversation UI"
          touch "$out"
        '';

        checks.generic-native = pkgs.runCommand "agentprolog-generic-native" {
          nativeBuildInputs = [ upstream pkgs.nodejs_22 ];
        } ''
          ${upstreamSwipl} -q \
            -s ${self}/test/agentprolog_config_test.pl \
            -s ${self}/test/agentprolog_agents_test.pl \
            -s ${self}/test/agentprolog_skills_test.pl \
            -s ${self}/test/agentprolog_check_tool_test.pl \
            -s ${self}/test/documented_configs_test.pl \
            -s ${self}/test/agentprolog_session_test.pl \
            -s ${self}/test/agentprolog_workspace_tools_test.pl -g "run_tests,halt"
          touch "$out"
        '';

        checks.native-skill-import = pkgs.runCommand "agentprolog-native-skill-import" {
          nativeBuildInputs = [ importSkill upstream ];
        } ''
          agentprolog-import-skill ${self}/skills/markdown-to-prolog "$TMPDIR/imported.pl"
          ${upstreamSwipl} -q -s ${self}/prolog/agentprolog_skills.pl \
            -g "load_skill_units(['$TMPDIR/imported.pl'],[_]),halt"
          touch "$out"
        '';

        checks.documentation = pkgs.runCommand "agentprolog-org-documentation" {
          nativeBuildInputs = [ upstream pkgs.nodejs_22 pkgs.python3 ];
        } ''
          export LANG=C.UTF-8
          export LC_ALL=C.UTF-8
          python3 -B ${self}/scripts/check-docs.py --root ${self}
          python3 -B -m unittest discover -s ${self}/test -p test_documentation.py
          python3 -B ${self}/scripts/check-tutorial.py \
            --runtime-lib ${upstream}/share/swi-prolog/pack/prolog_rlm/prolog \
            --swipl ${upstreamSwipl} --node ${pkgs.nodejs_22}/bin/node
          touch "$out"
        '';

        checks.documented-scripts = pkgs.runCommand "agentprolog-documented-scripts" {
          nativeBuildInputs = [ pkgs.nodejs_22 pkgs.bash ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          node --test ${self}/packages/conversation-ui/test/documented-scripts.test.js
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
