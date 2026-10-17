:- set_prolog_flag(on_error,status).
:- use_module(library(plunit)).
:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_effect)).
:- use_module(library(rlm_authority)).
:- use_module('../prolog/agentprolog_tools').
:- use_module('../prolog/agentprolog_language').
:- use_module('../prolog/agentprolog_process_tools').
:- initialization(main,main).

main(_) :-
    (getenv('AGENTPROLOG_SWIPL',_),getenv('AGENTPROLOG_SBCL',_)
    -> (run_tests(language_compilers) -> halt(0);halt(1))
    ; writeln(user_error,'Set AGENTPROLOG_SWIPL and AGENTPROLOG_SBCL to absolute executable paths'),halt(1)).

:- begin_tests(language_compilers).
setup_case(state(Root,Store)) :-
    uuid(Id),atom_concat('/tmp/agentprolog-language-',Id,Root),make_directory(Root),
    directory_file_path(Root,'effects.pl',Store),rlm_effect_store_open(Store),
    rlm_set_authority(session(language_fixture),dangerous,ok(_)).
cleanup_case(state(Root,_)) :-
    rlm_authority_clear(session(language_fixture)),rlm_effect_store_close,
    delete_directory_and_contents(Root).
write_source(Root,Name,Text) :-
    directory_file_path(Root,Name,File),
    setup_call_cleanup(open(File,write,S,[encoding(utf8)]),format(S,'~s',[Text]),close(S)).
invoke(R,Name,Args,V) :-
    tool_invoke(R,[tool(Name)],Name,Args,[authority_context(session(language_fixture))],Outcome,_),
    (Outcome=ok(Result) -> V=Result.value;throw(error(fixture_tool(Name,Outcome),_))).
registry(Root,Profile,R) :-
    tool_registry_create(R),coding_tools_load(R,Root,ok(_)),
    language_experts_load(R,ok(_)),process_tools_load(R,Root,[Profile],ok(_)).

repair_then_test(Root,Language,File,Source,Replacement,Profile) :-
    setup_call_cleanup(registry(Root,Profile,R),
        (invoke(R,run_tests,_{profile:"check"},Failed),assertion(Failed.status==failed),
         invoke(R,compiler_diagnostics_expert,
             _{language:Language,output:Failed.output,exit_code:Failed.exit_code},Diagnostic),
         assertion(Diagnostic.status==failed),
         invoke(R,project_analyze,_{path:File},Analysis),
         member(D,Analysis.definitions),D.name=="answer",
         invoke(R,source_edit_expert,
             _{language:Language,content:Source,path:File,start:D.start,replacement:Replacement},Proposal),
         assertion(Proposal.status==proposed),
         invoke(R,project_write,Proposal.arguments,_)),tool_registry_destroy(R)),
    setup_call_cleanup(registry(Root,Profile.put(snapshot,"after-edit"),R2),
        (invoke(R2,run_tests,_{profile:"check"},Passed),assertion(Passed.status==passed)),
        tool_registry_destroy(R2)).

test(prolog_real_repair,[setup(setup_case(S)),cleanup(cleanup_case(S))]) :-
    S=state(Root,_),getenv('AGENTPROLOG_SWIPL',Exe),
    Source=":- use_module(library(plunit)).\nanswer(41).\n:- begin_tests(fixture).\ntest(answer) :- answer(42).\n:- end_tests(fixture).\n",
    write_source(Root,'fixture.pl',Source),
    Profile=profile{id:"check",snapshot:"before-edit",executable:Exe,
        argv:['-q','-s','fixture.pl','-g','(run_tests -> halt(0);halt(1))'],env:[],kind:test,seconds:10},
    repair_then_test(Root,"prolog","fixture.pl",Source,"answer(42).",Profile).

test(lisp_real_repair,[setup(setup_case(S)),cleanup(cleanup_case(S))]) :-
    S=state(Root,_),getenv('AGENTPROLOG_SBCL',Exe),
    Source="(defun answer () 41)\n",write_source(Root,'fixture.lisp',Source),
    write_source(Root,'runner.lisp',
        "(multiple-value-bind (file warnings failure) (compile-file \"fixture.lisp\") (declare (ignore warnings)) (when failure (sb-ext:exit :code 1)) (load file))\n(assert (= (answer) 42))\n"),
    Profile=profile{id:"check",snapshot:"before-edit",executable:Exe,
        argv:['--script','runner.lisp'],env:[],kind:test,seconds:10},
    setup_call_cleanup(registry(Root,Profile,R),
        (invoke(R,run_tests,_{profile:"check"},Failed),assertion(Failed.status==failed),
         invoke(R,project_analyze,_{path:"fixture.lisp"},Analysis),Analysis.definitions=[D],
         assertion(D.name=="ANSWER"),
         invoke(R,source_edit_expert,
             _{language:"common_lisp",content:Source,path:"fixture.lisp",start:D.start,
               replacement:"(defun answer () 42)"},Proposal),
         assertion(Proposal.status==proposed),invoke(R,project_write,Proposal.arguments,_)),
        tool_registry_destroy(R)),
    setup_call_cleanup(registry(Root,Profile.put(snapshot,"after-edit"),R2),
        (invoke(R2,run_tests,_{profile:"check"},Passed),assertion(Passed.status==passed)),
        tool_registry_destroy(R2)).
:- end_tests(language_compilers).
