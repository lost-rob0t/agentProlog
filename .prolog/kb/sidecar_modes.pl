:- module(sidecar_modes, [mode_inherits_runtime_options/2]).

% Verified by prolog/agentprolog_dsh_sidecar_test.pl and the
% sidecar-mode-options flake check.
mode_inherits_runtime_options('symbolic-recursive',
                              [provider, provider_name, cancel_token, session_id]).
