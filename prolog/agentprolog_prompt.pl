:- module(agentprolog_prompt,[prepare_runtime_options/4,projected_request/3,configured_model/5]).

/** Product configuration projection through the one upstream prompt compiler.
    Transport, looping, tools, authority and budgets stay in Prolog-RLM. */
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(rlm_prompt_compiler)).
:- use_module(library(rlm_chain),[]).
:- use_module('./agentprolog_skills').

prepare_runtime_options(Config,Registry,Objective,Options) :-
    (get_dict(skill_files,Config,Files) -> true ; Files=[]),
    option(system_prompt(System),Config.runtime_options,""),
    (Files==[],System=="" -> Options=Config.runtime_options
    ; load_skill_units(Files,Skills),
      setup_call_cleanup(prompt_catalog_create(Catalog),
        compile_context(Catalog,Config,Registry,Objective,Skills,System,Messages),prompt_catalog_destroy(Catalog)),
      option(provider(Provider),Config.runtime_options,default),
      (Provider==default -> rlm_chain:default_openrouter_model(Model),rlm_chain:openrouter_provider(Model,Actual)
       ; Actual=Provider),
      (Actual=provider(DefaultName,_) -> true ; DefaultName=openrouter),
      option(provider_name(Name),Config.runtime_options,DefaultName),
      option(model_handler(ModelHandler),Config.runtime_options,none),
      option(planner_handler(PlannerHandler),Config.runtime_options,none),
      exclude(projected_option,Config.runtime_options,Base),
      append(Base,[provider(Actual),provider_name(Name),
        model_handler(agentprolog_prompt:configured_model(Actual,Messages,ModelHandler)),
        planner_handler(agentprolog_prompt:configured_model(Actual,Messages,PlannerHandler))],Options)
    ).
projected_option(O) :- functor(O,K,1),memberchk(K,[provider,provider_name,system_prompt,model_handler,planner_handler]).

compile_context(Catalog,Config,Registry,Objective,Skills,System,Messages) :-
    maplist(register(Catalog),Skills),
    prompt_catalog_register_tool_registry(Catalog,Registry,[],ToolResult),require_ok(ToolResult,_),
    (System=="" -> SelectedInstructions=[]
     ; register(Catalog,prompt_unit{unit:instruction(agent_configuration),description:"Trusted agent instructions",
         content:System,activation:always,mandatory_context:true}),
       SelectedInstructions=[instruction(agent_configuration)]),
    (get_dict(selected_skills,Config,Names) -> true ; Names=[]),
    maplist(skill_ref,Names,SelectedSkills),append(SelectedInstructions,SelectedSkills,Selected),
    Limit is max(1,min(4096,Config.budget.max_total_tokens//4)),
    Policy=_{max_context_tokens:Limit,provider_context_tokens:Limit,reserve_output_tokens:0,
             safety_margin_tokens:0,min_recent_turns:0,overflow:deny},
    prompt_compile(Catalog,prompt_input{text:Objective,selected:Selected},
      [capabilities(Config.capabilities),policy(Policy)],Result),require_ok(Result,Compiled),
    forall(member(Unit,SelectedSkills),
      (memberchk(Unit,Compiled.selected_units) -> true
       ; throw(error(agentprolog_skills(selection_rejected(Unit)),_)))),
    prompt_render(Compiled,openrouter,RenderedResult),require_ok(RenderedResult,Rendered),
    Messages=[message{role:system,content:Rendered.text}].
skill_ref(Name,skill(Name)).
register(C,U) :- prompt_catalog_register(C,U,R),require_ok(R,_).
require_ok(ok(V),V) :- !.
require_ok(error(E),_) :- throw(error(agentprolog_skills(compiler(E)),_)).

% This host callback is intentionally non-streaming. It forwards through the
% existing canonical provider wrapper; it is not another provider implementation.
configured_model(Provider,Messages,none,Request,Outcome) :- !,
    rlm_chain:model_complete_execute(provider_context(Messages,Provider),Request,Outcome).
configured_model(Provider,Messages,Handler,Request,Outcome) :-
    projected_request(agentprolog_prompt:configured_model(Provider,Messages,Handler),Request,Projected),
    call(Handler,Projected,Outcome).
projected_request(agentprolog_prompt:configured_model(_,Messages,_),Request,Projected) :-
    append(Messages,Request.messages,All),put_dict(messages,Request,All,Projected).
