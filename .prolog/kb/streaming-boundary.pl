:- module(agentprolog_streaming_kb,
          [upstream_stream_contract/3,
           upstream_stream_projection/3,
           downstream_stream_transport/2]).

/* Verified against prolog-rlm 51d2530 and AgentProlog's sidecar boundary. */
upstream_stream_contract(prolog_rlm, text_delta_handler, stream_message).
upstream_stream_projection(prolog_agent_ui_facade, ui_stream_handler, agent_event).
downstream_stream_transport(agentprolog_dsh_sidecar, ndjson_event).
