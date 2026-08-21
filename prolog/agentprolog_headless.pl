:- module(agentprolog_headless,
          [ headless_run/6
          ]).

/** <module> Standalone AgentProlog headless workflow composition

Product-level composition over the public Prolog-RLM Spec/Plan/Execute/Verify
APIs. Runtime scheduling, verification, authority, effects and repair semantics
remain owned by Prolog-RLM.
*/

:- use_module(library(rlm_spec)).
:- use_module(library(rlm_spec_workflow)).

headless_run(SpecInput, Registry, WorkflowConfig, FreezeOptions, RunOptions, Outcome) :-
    catch(headless_run_(SpecInput,
                        Registry,
                        WorkflowConfig,
                        FreezeOptions,
                        RunOptions,
                        Outcome),
          Error,
          Outcome = error(agentprolog_headless_error(Error))).

headless_run_(SpecInput, Registry, WorkflowConfig, FreezeOptions, RunOptions,
              ok(Result)) :-
    spec_normalize(SpecInput, NormalizeOutcome),
    require_ok(normalize, NormalizeOutcome, Normalized),
    spec_validate(Normalized, Registry, ValidateOutcome),
    require_ok(validate, ValidateOutcome, Validated),
    spec_freeze(Validated, FreezeOptions, FreezeOutcome),
    require_ok(freeze, FreezeOutcome, Frozen),
    spec_workflow_compile(Frozen,
                          Registry,
                          WorkflowConfig,
                          [],
                          CompileOutcome),
    require_ok(compile, CompileOutcome, Workflow),
    spec_workflow_run(Workflow, RunOptions, RunOutcome),
    require_ok(run, RunOutcome, WorkflowResult),
    Result = headless_result{
                 spec_ref:Frozen.ref,
                 frozen_spec:Frozen,
                 workflow:WorkflowResult
             }.

require_ok(_, ok(Value), Value) :- !.
require_ok(Stage, Outcome, _) :-
    throw(stage_failed(Stage, Outcome)).
