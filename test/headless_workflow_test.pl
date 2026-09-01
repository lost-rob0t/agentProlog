:- begin_tests(agentprolog_headless).

:- use_module('../prolog/agentprolog_headless').

registry([
    assertion_provider(always_true,
                       1,
                       plunit_agentprolog_headless:validate_args,
                       plunit_agentprolog_headless:evaluate,
                       plunit_agentprolog_headless:observe,
                       _{ verifier:_{id:fixture_verifier,version:1},
                          collector:_{id:fixture_collector,version:1},
                          evidence_policy:_{ required_evidence:true,
                                             source_classes:[fixture],
                                             trust_classes:[observed],
                                             freshness:current,
                                             coherence:run,
                                             state_ref:any
                                           },
                          latency:pure,
                          description:"headless conformance fixture"
                        })
]).

validate_args(Args) :- is_dict(Args).

evaluate(_, Observation, Status) :-
    ( Observation.value == true -> Status = passed ; Status = failed ).

observe(_, _, _,
        _{ status:passed,
           value:true,
           evidence_refs:[fixture_evidence],
           source_class:fixture,
           trust_class:observed,
           provenance:_{source:test},
           snapshot:fixture_snapshot,
           freshness:current,
           coherence:run,
           state_ref:fixture_state
         }).

input_spec(_{
    schema_version:1,
    subject:_{project:agentprolog},
    requirements:[_{ id:headless,
                     assertion:assertion(always_true, _{}),
                     severity:required,
                     provenance:_{source:test}
                   }],
    provenance:_{source:test_suite}
}).

test(headless_composes_public_runtime_and_preserves_frozen_spec) :-
    registry(Registry),
    input_spec(Input),
    Config = _{ plan:plan([final(done)]),
                observation_sources:[fixture],
                max_repairs:0
              },
    headless_run(Input,
                 Registry,
                 Config,
                 [series(agentprolog_headless),version(1)],
                 [],
                 ok(Result)),
    assertion(Result.workflow.status == completed),
    assertion(Result.workflow.state.status == passed),
    assertion(Result.workflow.state.spec_ref == Result.spec_ref),
    assertion(Result.frozen_spec.ref == Result.spec_ref).

test(verification_failure_is_not_reported_as_success) :-
    registry(Registry),
    input_spec(Input),
    Config = _{ plan:plan([final(done)]),
                observation_sources:[],
                max_repairs:0
              },
    headless_run(Input,
                 Registry,
                 Config,
                 [series(agentprolog_headless_failure),version(1)],
                 [],
                 ok(Result)),
    assertion(Result.workflow.state.status \== passed).

:- end_tests(agentprolog_headless).
