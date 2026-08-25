{
  description = "AgentProlog standalone coding-agent product";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    prolog-rlm = {
      # Exact reviewed runtime head used by the #184 downstream integration.
      url = "github:lost-rob0t/prolog-rlm/a5e0a28b47fada46a15fe439d58bf2940ec224e7";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        upstream = prolog-rlm.packages.${system}.default;
        upstreamSwipl = "${upstream}/bin/prolog-rlm-swipl";

        sidecar = pkgs.writeShellApplication {
          name = "agentprolog-dsh-sidecar";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstreamSwipl} -q -s ${./prolog/agentprolog_dsh_sidecar.pl} -- "$@"
          '';
        };

        runtimeProbe = pkgs.writeShellApplication {
          name = "agentProlog";
          runtimeInputs = [ upstream ];
          text = ''
            exec ${upstreamSwipl} -q -g "use_module(library(rlm)),writeln('AgentProlog runtime ready'),halt" -- "$@"
          '';
        };
      in {
        packages.agentProlog = runtimeProbe;
        packages.sidecar = sidecar;
        packages.default = runtimeProbe;

        apps.agentProlog = flake-utils.lib.mkApp { drv = runtimeProbe; };
        apps.sidecar = flake-utils.lib.mkApp { drv = sidecar; };
        apps.default = self.apps.${system}.agentProlog;

        devShells.default = pkgs.mkShell {
          packages = [ upstream pkgs.nodejs_24 pkgs.corepack pkgs.git ];
          shellHook = ''
            export AGENTPROLOG_SIDECAR=${sidecar}/bin/agentprolog-dsh-sidecar
            export AGENTPROLOG_DSH_PLUGIN="$PWD/packages/deepseek-harness/src/plugin.js"
          '';
        };

        checks.runtime-load = pkgs.runCommand "agentprolog-runtime-load" {
          nativeBuildInputs = [ upstream ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cd "$TMPDIR"
          ${upstreamSwipl} -q -g "use_module(library(rlm)),halt"
          touch "$out"
        '';

        checks.sidecar-load = pkgs.runCommand "agentprolog-dsh-sidecar-load" {
          nativeBuildInputs = [ upstream ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          ${upstreamSwipl} -q -g "use_module('${./prolog/agentprolog_dsh_sidecar.pl}'),halt"
          touch "$out"
        '';

        checks.sidecar-protocol = pkgs.runCommand "agentprolog-dsh-sidecar-protocol" {
          nativeBuildInputs = [ sidecar pkgs.jq ];
        } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cat > "$TMPDIR/input.jsonl" <<'EOF'
          {"version":1,"request_id":"describe-1","session_id":"bridge","operation":"runtime.describe","payload":{}}
          {"version":1,"request_id":"start-1","session_id":"smoke","operation":"session.start","payload":{}}
          {"version":1,"request_id":"inspect-1","session_id":"smoke","operation":"session.inspect","payload":{}}
          EOF
          agentprolog-dsh-sidecar < "$TMPDIR/input.jsonl" > "$TMPDIR/output.jsonl"
          test "$(wc -l < "$TMPDIR/output.jsonl")" -eq 3
          sed -n '1p' "$TMPDIR/output.jsonl" | jq -e '.status == "ok" and .payload.protocol_version == 1 and .payload.capabilities.agent_factory == true'
          sed -n '2p' "$TMPDIR/output.jsonl" | jq -e '.status == "ok" and .payload.started == true'
          sed -n '3p' "$TMPDIR/output.jsonl" | jq -e '.status == "ok" and .payload.busy == false'
          touch "$out"
        '';

        checks.default-app = pkgs.runCommand "agentprolog-default-app" {
          nativeBuildInputs = [ runtimeProbe ];
        } ''
          agentProlog | grep -F "AgentProlog runtime ready"
          touch "$out"
        '';
      });
}
