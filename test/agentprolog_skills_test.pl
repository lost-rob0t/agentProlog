:- begin_tests(agentprolog_skills).
:- use_module('../prolog/agentprolog_skills').
:- use_module('../prolog/agentprolog_prompt').
:- use_module('../prolog/agentprolog_config').
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(rlm_tool)).

setup_root(Root) :- tmp_file(native_skills,Root),make_directory(Root).
cleanup_root(Root) :- delete_directory_and_contents(Root).
text_file(Root,Name,Text,Path) :- directory_file_path(Root,Name,Path),
    setup_call_cleanup(open(Path,write,S),format(S,'~s',[Text]),close(S)).
unit_file(Root,Unit,Path) :- directory_file_path(Root,'skills.pl',Path),
    setup_call_cleanup(open(Path,write,S),write_term(S,agentprolog_skills([Unit]),[quoted(true),fullstop(true),nl(true)]),close(S)).

test(markdown_import_is_inert_native_compiler_ir,[setup(setup_root(R)),cleanup(cleanup_root(R))]) :-
    directory_file_path(R,source,D),make_directory(D),
    text_file(D,'SKILL.md',"---\nname: build-todo\ndescription: Build a todo application\n---\nNATIVE_IMPORT_MARKER",_),
    directory_file_path(R,'imported.pl',Output),import_markdown(D,Output),
    load_skill_units([Output],[Unit]),
    assertion(Unit.unit == skill('build-todo')),assertion(Unit.content == "NATIVE_IMPORT_MARKER"),
    assertion(sub_string(Unit.provenance,_,_,_,"SKILL.md")),
    assertion(Unit.mandatory_context == false).

test(directives_in_native_files_are_not_executed,[setup(setup_root(R)),cleanup(cleanup_root(R)),
     throws(error(agentprolog_skills(invalid_document(_)),_))]) :-
    text_file(R,'bad.pl',":- throw(native_skill_executed).",P),load_skill_units([P],_).

test(multiple_terms_rejected,[setup(setup_root(R)),cleanup(cleanup_root(R)),
     throws(error(agentprolog_skills(invalid_document(_)),_))]) :-
    text_file(R,'bad.pl',"agentprolog_skills([]). agentprolog_skills([]).",P),load_skill_units([P],_).

test(native_skills_cannot_pin_themselves,[setup(setup_root(R)),cleanup(cleanup_root(R)),
     throws(error(agentprolog_skills(forbidden_policy(mandatory_context)),_))]) :-
    unit_file(R,prompt_unit{unit:skill(bad),description:"bad",content:"bad",mandatory_context:true},P),
    load_skill_units([P],_).

test(selected_native_skill_and_system_instruction_reach_provider_request,
     [setup(setup_root(R)),cleanup(cleanup_root(R))]) :-
    unit_file(R,prompt_unit{unit:skill(todo),description:"todo app",content:"NATIVE_BODY_MARKER"},P),
    default_configuration(Base),
    put_dict(_{skill_files:[P],selected_skills:[todo],runtime_options:[system_prompt("HOST_SYSTEM_MARKER"),
        provider(provider(openai_compatible,[])),provider_name(openai_compatible)]},Base,C),
    setup_call_cleanup(tool_registry_create(Registry),
      (prepare_runtime_options(C,Registry,"build a todo app",Options),
       member(model_handler(Handler),Options),
       agentprolog_prompt:projected_request(Handler,model_request{messages:[message{role:user,content:"task"}],options:_{}},Request),
       findall(Text,(member(M,Request.messages),M.role==system,Text=M.content),Texts),
       atomics_to_string(Texts," ",All),
       assertion(sub_string(All,_,_,_,"NATIVE_BODY_MARKER")),
       assertion(sub_string(All,_,_,_,"HOST_SYSTEM_MARKER"))),tool_registry_destroy(Registry)), !.

test(unknown_selected_skill_fails_before_provider,
     [setup(setup_root(R)),cleanup(cleanup_root(R)),
      throws(error(agentprolog_skills(selection_rejected(skill(missing))),_))]) :-
    unit_file(R,prompt_unit{unit:skill(todo),description:"todo",content:"body"},P),
    default_configuration(Base),put_dict(_{skill_files:[P],selected_skills:[missing]},Base,C),
    setup_call_cleanup(tool_registry_create(Registry),
      prepare_runtime_options(C,Registry,"task",_),tool_registry_destroy(Registry)).

:- end_tests(agentprolog_skills).
