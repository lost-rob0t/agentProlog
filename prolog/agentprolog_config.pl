:- module(agentprolog_config,
          [load_configuration/3, default_configuration/1, register_config_tools/2, named_agent_configuration/3]).

/** <module> Explicitly trusted Prolog configuration for a generic agent host.

This is a loader, not a sandbox: a consulted plugin can execute arbitrary Prolog.
The host must obtain operator trust before supplying plugin/1 or trusted_project.
Use one sidecar process per project. Model output must never supply these options.
*/
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(time)).
:- use_module(library(solution_sequences)).
:- use_module(library(prolog_pack)).
:- use_module(library(rlm_tool)).
:- use_module('./agentprolog_skills').
:- dynamic known_source/2.

default_configuration(config{
    profile:generic, mode:direct, tools:[], capabilities:[], runtime_options:[],
    budget:_{max_model_calls:8, max_tool_calls:16, max_iterations:16,
              max_total_tokens:32768, max_output_bytes:262144,
              max_recursion_depth:1, max_concurrent_subcalls:2,
              max_context_ops:16, max_native_calls_per_batch:8,
              time_limit:120.0, max_cost_usd:0.25},
    hooks:_{}, sources:[], agents:_{}, default_agent:none, agent:none,
    skill_files:[], selected_skills:[]}).

load_configuration(Project0, Options0, Config) :-
    expand_operator_options(Options0,Options,OperatorSources),
    must_be(list, Options), maplist(valid_option, Options), unique_options(Options),
    absolute_file_name(Project0, Project, [file_type(directory), access(read), file_errors(error)]),
    prepare_packages(Options),
    findall(Path, (member(O,Options), config_source(O,Path)), PluginPaths0),
    maplist(source_path, PluginPaths0, PluginPaths),
    directory_file_path(Project, '.agentprolog/config.pl', ProjectPath),
    ( exists_file(ProjectPath)
    -> (option(trusted_project(Trust), Options, false), Trust == true
       -> source_path(ProjectPath, TrustedProject), append(PluginPaths, [TrustedProject], Sources)
       ; throw(error(agentprolog_config(untrusted_project(ProjectPath)), _)))
    ; Sources = PluginPaths ),
    sort(Sources, Unique), length(Sources, N), length(Unique, M),
    (N =:= M -> true ; throw(error(agentprolog_config(duplicate_source), _))),
    default_configuration(Default),
    option(allowed_capabilities(Allowed), Options, []), validate_caps(Allowed),
    option(budget_ceiling(OperatorBudget),Options,_{}),
    must_be(dict,OperatorBudget),dict_pairs(OperatorBudget,_,BudgetPairs),
    forall(member(K-V,BudgetPairs),(get_dict(K,Default.budget,_),valid_budget_value(K,V))),
    put_dict(OperatorBudget,Default.budget,OperatorCeiling),
    option(budget_limits(Limits0), Options, _{}),
    budget_merge(OperatorCeiling, Limits0, OperatorCeiling, Ceiling),
    put_dict(budget, Default, Ceiling, Base),
    foldl(load_layer(Allowed, Ceiling), Sources, Base, Config0),
    findall(Manifest,(member(package(P),Options),package_manifest(P,Manifest)),Manifests),
    append([Sources,Manifests,OperatorSources],AllSources),
    put_dict(_{project:Project, sources:AllSources}, Config0, Config1),
    option(agent(Name),Options,Config1.default_agent),
    select_agent(Name,Allowed,Config1,Selected),
    load_skill_units(Selected.skill_files,_),
    append(Selected.sources,Selected.skill_files,BoundSources),
    put_dict(sources,Selected,BoundSources,Config).

expand_operator_options(Options0,Options,Sources) :-
    must_be(list,Options0),
    findall(P,member(config_file(P),Options0),Files),
    (Files=[] -> Options=Options0,Sources=[]
     ; Files=[Path0],atom(Path0)
     -> source_path(Path0,Path),source_module(Path,agentprolog_options,Module),
        admit_module(Path,Module),
        catch((load_files(Path,[imports([]),silent(true)]),
          call_with_time_limit(5,findnsols(2,O,Module:agentprolog_options(O),Solutions)),
          (Solutions=[FileOptions],is_list(FileOptions) -> true
           ; throw(error(agentprolog_config(non_unique_operator_options),_))),
          maplist(valid_option,FileOptions)),Error,(unload_file(Path),throw(Error))),
        exclude(is_config_file,Options0,CLI),append(FileOptions,CLI,Options),Sources=[Path]
     ; throw(error(agentprolog_config(invalid_operator_config),_))).
is_config_file(config_file(_)).

config_source(plugin(Path),Path).
config_source(package(Root0),Entry) :-
    package_info(Root0,_,Root,_),
    directory_file_path(Root,'prolog/agentprolog_plugin.pl',Entry).
package_info(Root0,Name,Root,Manifest) :-
    absolute_file_name(Root0,Root,[file_type(directory),access(read)]),
    package_manifest(Root,Manifest),
    setup_call_cleanup(open(Manifest,read,S),read_term(S,First,[]),close(S)),
    (First=name(Name),atom(Name) -> true ; throw(error(agentprolog_config(invalid_pack(Root)),_))).
prepare_packages(Options) :-
    findall(Name-Root,(member(package(P),Options),package_info(P,Name,Root,_)),Packages),
    findall(Name,member(Name-_,Packages),Names),
    (select(Name,Names,Rest),memberchk(Name,Rest)
     -> throw(error(agentprolog_config(duplicate_package(Name)),_)) ; true),
    forall(member(_-Root,Packages),pack_attach(Root,[search(first)])).
package_manifest(Root,Manifest) :-
    directory_file_path(Root,'pack.pl',Path),
    absolute_file_name(Path,Manifest,[access(read),file_errors(error)]).

valid_option(plugin(Path)) :- atom(Path), !.
valid_option(package(Path)) :- atom(Path), !.
valid_option(agent(Name)) :- atom(Name), !.
valid_option(trusted_project(B)) :- memberchk(B, [true,false]), !.
valid_option(allowed_capabilities(C)) :- is_list(C), !.
valid_option(budget_limits(D)) :- is_dict(D), !.
valid_option(budget_ceiling(D)) :- is_dict(D), !.
valid_option(O) :- throw(error(agentprolog_config(invalid_option(O)), _)).
unique_options(Options) :-
    findall(Key, (member(O,Options), functor(O,Key,1), \+ memberchk(Key,[plugin,package])), Keys),
    sort(Keys,Unique), length(Keys,N), length(Unique,M),
    (N =:= M -> true ; throw(error(agentprolog_config(duplicate_option), _))).
source_path(Path0, Path) :-
    absolute_file_name(Path0, Path, [access(read), file_type(prolog), file_errors(error)]).

load_layer(Allowed, Ceiling, Path, Base, Config) :-
    source_module(Path, Module),
    admit_module(Path,Module),
    catch(( load_files(Path, [imports([]), silent(true)]),
            (current_predicate(Module:agentprolog_config/1) -> true
            ; throw(error(agentprolog_config(missing_config_predicate(Module)), _))),
            call_with_time_limit(5, findnsols(2, C, Module:agentprolog_config(C), Cs)),
            (Cs = [Layer] -> true ; throw(error(agentprolog_config(non_unique_configuration(Path)), _))),
            validate_layer(Layer),
            resolve_skill_paths(Path,Layer,Resolved),
            merge_layer(Base, Resolved, Allowed, Ceiling, Config)
          ), Error,
          (unload_file(Path), throw(Error))).

admit_module(Path,Module) :-
    ((module_property(Module, file(Existing));known_source(Module,Existing)), Existing \== Path
    -> throw(error(agentprolog_config(module_conflict(Module, Existing, Path)), _))
    ; true),
    (current_module(Module), \+ module_property(Module, file(Path)), \+ known_source(Module,Path)
    -> throw(error(agentprolog_config(reserved_module(Module)), _)) ; true),
    (known_source(Module,Path) -> true ; assertz(known_source(Module,Path))).

% Reading the module declaration does not execute its directives.
source_module(Path, Module) :- source_module(Path,agentprolog_config,Module).
source_module(Path, Predicate, Module) :-
    setup_call_cleanup(open(Path, read, Stream, [encoding(utf8)]),
                       read_term(Stream, Term, [syntax_errors(error)]), close(Stream)),
    (Term = (:- module(Module, Exports)), atom(Module), is_list(Exports),
     memberchk(Predicate/1, Exports)
    -> true
    ; throw(error(agentprolog_config(module_declaration_required(Path)), _))).

validate_layer(Layer) :-
    (is_dict(Layer) -> true ; throw(error(agentprolog_config(expected_dict), _))),
    dict_pairs(Layer, _, Pairs),
    forall(member(K-_, Pairs),
        (memberchk(K, [profile,mode,tools,capabilities,runtime_options,budget,hooks,
                      agents,default_agent,skill_files,selected_skills]) -> true
        ; throw(error(agentprolog_config(unknown_key(K)), _)))),
    (get_dict(profile, Layer, Profile) -> valid_profile(Profile) ; true),
    (get_dict(mode, Layer, Mode) -> member_or_error(Mode, [direct,rlm], invalid_mode) ; true),
    (get_dict(tools, Layer, Tools) -> must_be(list, Tools), maplist(valid_tool, Tools) ; true),
    (get_dict(capabilities, Layer, Caps) -> validate_caps(Caps) ; true),
    (get_dict(runtime_options, Layer, Opts) -> valid_runtime_options(Opts) ; true),
    (get_dict(budget, Layer, B) -> must_be(dict, B) ; true),
    (get_dict(hooks, Layer, H) -> valid_hooks(H) ; true),
    (get_dict(agents,Layer,Agents) -> must_be(dict,Agents),dict_pairs(Agents,_,AP),maplist(valid_agent,AP) ; true),
    (get_dict(default_agent,Layer,Name) -> must_be(atom,Name) ; true),
    (get_dict(skill_files,Layer,Files) -> must_be(list,Files),maplist(must_be(atom),Files) ; true),
    (get_dict(selected_skills,Layer,Skills) -> must_be(list,Skills),maplist(must_be(atom),Skills) ; true).

valid_agent(Name-Layer) :-
    must_be(atom,Name), must_be(dict,Layer),
    forall(member(Key,[agents,default_agent]),
      (get_dict(Key,Layer,_) -> throw(error(agentprolog_config(nested_agent_configuration(Name)),_)) ; true)),
    validate_layer(Layer).

resolve_skill_paths(Source,Layer,Resolved) :-
    file_directory_name(Source,Directory),
    (get_dict(skill_files,Layer,Files)
     -> maplist(relative_source(Directory),Files,Paths),put_dict(skill_files,Layer,Paths,L1)
     ; L1=Layer),
    (get_dict(agents,L1,Agents)
     -> dict_pairs(Agents,Tag,Pairs),maplist(resolve_agent_paths(Source),Pairs,NewPairs),
        dict_pairs(NewAgents,Tag,NewPairs),put_dict(agents,L1,NewAgents,Resolved)
     ; Resolved=L1).
resolve_agent_paths(Source,Name-Layer,Name-Resolved) :- resolve_skill_paths(Source,Layer,Resolved).
relative_source(Directory,Path,Absolute) :-
    absolute_file_name(Path,Absolute,[relative_to(Directory),access(read),file_errors(error)]).

named_agent_configuration(Base,Name,Config) :-
    get_dict(Name,Base.agents,_),select_agent(Name,Base.capabilities,Base,Config).
select_agent(none,_,Config,Config) :- !.
select_agent(Name,Allowed,Base,Config) :-
    (get_dict(Name,Base.agents,Layer) -> true ; throw(error(agentprolog_config(unknown_agent(Name)),_))),
    (get_dict(capabilities,Layer,Caps)
     -> forall(member(C,Caps),(memberchk(C,Base.capabilities) -> true
             ; throw(error(agentprolog_config(agent_capability_expansion(C)),_))))
     ; true),
    merge_layer(Base,Layer,Allowed,Base.budget,Selected),
    override_option(agent_name(Name),Selected.runtime_options,Options),
    put_dict(_{agent:Name,runtime_options:Options},Selected,Config).

valid_profile(P) :- atom(P), P \== '', !.
valid_profile(P) :- string(P), P \== "", !.
valid_profile(P) :- throw(error(agentprolog_config(invalid_profile(P)), _)).
member_or_error(V, Allowed, Code) :-
    (memberchk(V, Allowed) -> true ; throw(error(agentprolog_config(Code-V), _))).
validate_caps(Caps) :-
    must_be(list, Caps),
    capabilities_normalize(Caps, Validated),
    (Validated = ok(_) -> true ; throw(error(agentprolog_config(invalid_capabilities(Validated)), _))),
    sort(Caps, Unique), length(Caps, N), length(Unique, M),
    (N =:= M -> true ; throw(error(agentprolog_config(duplicate_capability), _))).
qualified(tool_handler(Preflight, Execute)) :- !, qualified(Preflight), qualified(Execute).
qualified(H) :- qualified_closure(H).
qualified_closure(M:G) :- atom(M), callable(G), ground(G), !.
qualified_closure(H) :- throw(error(agentprolog_config(qualified_handler_required(H)), _)).
valid_tool(tool(Schema, Handler)) :-
    is_dict(Schema), qualified(Handler), !,
    setup_call_cleanup(tool_registry_create(Registry),
      (tool_register(Registry, Schema, Handler, Result),
       (Result = ok(_) -> true ; throw(error(agentprolog_config(invalid_tool(Result)), _)))),
      tool_registry_destroy(Registry)).
valid_tool(Tool) :- throw(error(agentprolog_config(invalid_tool(Tool)), _)).

valid_runtime_options(Options) :-
    must_be(list, Options),
    maplist(runtime_option_key, Options, Keys),
    sort(Keys, Unique), length(Keys, N), length(Unique, M),
    (N =:= M -> true ; throw(error(agentprolog_config(duplicate_runtime_option), _))).
runtime_option_key(Option, Key) :-
    compound(Option), compound_name_arity(Option, Key, 1),
    memberchk(Key, [provider,provider_name,model_handler,planner_handler,prompt_compile_mode,system_prompt,
                   agent_name,planner_max_tokens,history_depth,subagents,army_max_children,stream_responses,image_inputs]),
    ground(Option), !,
    (Key==army_max_children -> arg(1,Option,N),must_be(integer,N),between(1,32,N)
    ; Key==subagents -> arg(1,Option,V), memberchk(V,[true,false])
    ; memberchk(Key,[stream_responses,image_inputs]) -> arg(1,Option,B),memberchk(B,[true,false])
    ; Key==history_depth -> arg(1,Option,N), must_be(integer,N), between(0,32,N)
    ; memberchk(Key,[model_handler,planner_handler])
    -> arg(1,Option,Handler), qualified_closure(Handler)
    ; true).
runtime_option_key(Option, _) :- throw(error(agentprolog_config(unsupported_runtime_option(Option)), _)).
valid_hooks(Hooks) :-
    must_be(dict, Hooks), dict_pairs(Hooks, _, Pairs),
    forall(member(K-H, Pairs),
      (memberchk(K, [validate_artifact]) -> qualified_closure(H)
      ; throw(error(agentprolog_config(unknown_hook(K)), _)))).

merge_layer(Base, Layer, Allowed, Ceiling, Config) :-
    dict_default(Layer, tools, [], Added), append(Base.tools, Added, Tools),
    maplist(tool_name, Tools, Names), sort(Names, Unique), length(Names,N), length(Unique,M),
    (N =:= M -> true ; throw(error(agentprolog_config(duplicate_tool_name), _))),
    dict_default(Layer, capabilities, Base.capabilities, Caps),
    forall(member(C, Caps), (memberchk(C, Allowed) -> true
                           ; throw(error(agentprolog_config(capability_not_granted(C)), _)))),
    forall(member(tool(Name), Caps), (memberchk(Name, Names) -> true
                                    ; throw(error(agentprolog_config(capability_without_tool(Name)), _)))),
    dict_default(Layer, runtime_options, [], NewOptions),
    foldl(override_option, NewOptions, Base.runtime_options, Options),
    dict_default(Layer, budget, _{}, NewBudget), budget_merge(Base.budget, NewBudget, Ceiling, Budget),
    dict_default(Layer, hooks, _{}, NewHooks), put_dict(NewHooks, Base.hooks, Hooks),
    dict_default(Layer, profile, Base.profile, Profile),
    dict_default(Layer, mode, Base.mode, Mode),
    dict_default(Layer, agents, _{}, AddedAgents), dict_pairs(AddedAgents,_,AgentPairs),
    forall(member(Name-_,AgentPairs),(get_dict(Name,Base.agents,_) -> throw(error(agentprolog_config(duplicate_agent(Name)),_)) ; true)),
    put_dict(AddedAgents,Base.agents,Agents),
    dict_default(Layer, default_agent, Base.default_agent, DefaultAgent),
    dict_default(Layer, skill_files, [], AddedFiles),append(Base.skill_files,AddedFiles,SkillFiles),
    dict_default(Layer, selected_skills, Base.selected_skills, SelectedSkills),
    put_dict(_{profile:Profile,mode:Mode,tools:Tools,capabilities:Caps,
               runtime_options:Options,budget:Budget,hooks:Hooks,agents:Agents,
               default_agent:DefaultAgent,skill_files:SkillFiles,selected_skills:SelectedSkills}, Base, Config).
tool_name(tool(Schema,_), Name) :- Name = Schema.name.
dict_default(Dict, Key, Default, Value) :- (get_dict(Key,Dict,Found) -> Value=Found ; Value=Default).
override_option(Option, Old, New) :-
    runtime_option_key(Option, Key), exclude(has_key(Key), Old, Rest), append(Rest,[Option],New).
has_key(Key, Option) :- compound_name_arity(Option, Key, 1).
budget_merge(Base, Requested, Ceiling, Budget) :-
    must_be(dict, Requested), dict_pairs(Requested, _, Pairs),
    forall(member(Key-Value, Pairs),
       (get_dict(Key, Ceiling, Limit), valid_budget_value(Key, Value), Value =< Limit
       -> true ; throw(error(agentprolog_config(invalid_budget(Key,Value)), _)))),
    put_dict(Requested, Base, Budget).

valid_budget_value(Key, Value) :-
    (memberchk(Key,[time_limit,max_cost_usd]) -> number(Value) ; integer(Value)),
    (memberchk(Key,[max_tool_calls,max_recursion_depth,max_cost_usd]) -> Value >= 0 ; Value > 0).

register_config_tools(Config, Registry) :-
    forall(member(tool(Schema,Handler), Config.tools),
      (tool_register(Registry, Schema, Handler, Outcome),
       (Outcome = ok(_) -> true ; throw(error(agentprolog_config(tool_registration_failed(Outcome)), _))))).
