{
  description = "AgentProlog: Prolog-RLM coding-agent layer as a DeepSeek Harness plugin";

  inputs = {
    # Shared with prolog-rlm's lock so both flakes build from one nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/bfc1b8a4574108ceef22f02bafcf6611380c100d";
    flake-utils.url = "github:numtide/flake-utils";
    # Current reviewed Prolog-RLM head. Every sidecar and check consumes the
    # public `prolog_rlm` pack built by that flake; bump this pin together
    # with the compatibility pin in packages/agentprolog/src/compatibility.ts.
    prolog-rlm = {
      url = "github:lost-rob0t/prolog-rlm/8e7b00934824f329acb373ea086be6294f67f9d3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        swiProlog = pkgs.swi-prolog;
        prologRlm = prolog-rlm.packages.${system}.prolog-rlm;
        prologRlmPack = "${prologRlm}/share/swi-prolog/pack";
        prologRlmRev = "8e7b00934824f329acb373ea086be6294f67f9d3";

        # Persistent Prolog sidecar consumed by the DSH plugin as
        # config.command. The wrapper pins both the SWI-Prolog build and the
        # prolog-rlm pack closure, so no host swipl installation is used.
        sidecar = pkgs.stdenvNoCC.mkDerivation {
          pname = "agentprolog-sidecar";
          version = "0.1.0";
          src = ./prolog;
          dontBuild = true;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/lib/agentprolog" "$out/bin"
            cp agentprolog_dsh_sidecar.pl "$out/lib/agentprolog/"
            makeWrapper ${swiProlog}/bin/swipl "$out/bin/agentprolog-sidecar" \
              --add-flags "-q" \
              --add-flags "-s $out/lib/agentprolog/agentprolog_dsh_sidecar.pl" \
              --add-flags "--" \
              --add-flags "stdio" \
              --prefix SWIPL_PACK_PATH : "${prologRlmPack}"
            runHook postInstall
          '';
          passthru = {
            prologRlmRev = prologRlmRev;
            swiPrologVersion = swiProlog.version;
          };
        };
      in
      {
        packages.agentprolog-sidecar = sidecar;
        packages.default = sidecar;

        apps.sidecar = {
          type = "app";
          program = "${sidecar}/bin/agentprolog-sidecar";
        };
        apps.default = self.apps.${system}.sidecar;

        devShells.default = pkgs.mkShell {
          packages = [ swiProlog prologRlm sidecar pkgs.nodejs_24 pkgs.pnpm pkgs.git ];
          SWIPL_PACK_PATH = prologRlmPack;
          AGENTPROLOG_SIDECAR = "${sidecar}/bin/agentprolog-sidecar";
          shellHook = ''
            echo "agentprolog devshell: node $(node --version), pnpm $(pnpm --version), swipl $(swipl --version 2>&1 | cut -d' ' -f1), sidecar $(command -v agentprolog-sidecar)"
          '';
        };

        checks = {
          # Pinned prolog-rlm pack loads and reports ready through the public
          # facade, mirroring upstream's own packaged-library-load check.
          prolog-rlm-pack-load = pkgs.runCommand "prolog-rlm-pack-load" {
            nativeBuildInputs = [ swiProlog ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "$TMPDIR"
            SWIPL_PACK_PATH="${prologRlmPack}" swipl -q -g "use_module(library(rlm)),rlm:rlm_ready,halt"
            touch "$out"
          '';

          # The packaged sidecar answers a keyless runtime.describe frame over
          # its real NDJSON stdio transport.
          sidecar-protocol-smoke = pkgs.runCommand "sidecar-protocol-smoke" {
            nativeBuildInputs = [ sidecar ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "$TMPDIR"
            printf '%s\n' '{"version":1,"request_id":"smoke-1","session_id":"smoke","operation":"runtime.describe","payload":{}}' \
              | agentprolog-sidecar 2>/dev/null | grep -F '"protocol_version":1'
            touch "$out"
          '';

          # Mode validation and unknown-session failure paths stay fail-closed
          # through the real sidecar.
          sidecar-mode-validation = pkgs.runCommand "sidecar-mode-validation" {
            nativeBuildInputs = [ sidecar pkgs.jq ];
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "$TMPDIR"
            {
              printf '%s\n' '{"version":1,"request_id":"m1","session_id":"s","operation":"session.mode","payload":{"mode":"bogus"}}'
              printf '%s\n' '{"version":1,"request_id":"m2","session_id":"ghost","operation":"session.mode","payload":{"mode":"symbolic"}}'
            } | agentprolog-sidecar 2>/dev/null > replies.ndjson
            grep -F '"request_id":"m1"' replies.ndjson | grep -F '"status":"error"' | grep -F 'invalid_mode' >/dev/null
            grep -F '"request_id":"m2"' replies.ndjson | grep -F '"status":"error"' | grep -F 'session_not_found' >/dev/null
            touch "$out"
          '';
        };
      });
}
