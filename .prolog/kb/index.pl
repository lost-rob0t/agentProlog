:- module(agentprolog_kb,
          [mode_inherits_runtime_options/2,
           suite_prerequisite/2,
           upstream_stream_contract/3,
           upstream_stream_projection/3,
           downstream_stream_transport/2]).

:- use_module('sidecar_modes.pl').
:- use_module('verification_workflow.pl').
:- use_module('streaming-boundary.pl').
