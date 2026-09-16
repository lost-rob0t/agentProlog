:- use_module(library(plunit)).
:- begin_tests(language_tools).
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_expert)).
:- use_module('../prolog/agentprolog_language').

setup_registry(R) :- tool_registry_create(R),language_experts_load(R,ok(_)).
invoke(R,Name,Args,Value) :-
    tool_invoke(R,[tool(Name)],Name,Args,[],ok(Result),_),Value=Result.value.

test(lisp_structural_edit,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    Source="(in-package :demo)\n(defun x () 1)\n(defun y () 2)",
    invoke(R,source_inspect_expert,_{language:"common_lisp",content:Source},A),
    member(D,A.definitions),D.name=="X",
    invoke(R,source_edit_expert,_{language:"common_lisp",content:Source,path:"test.lisp",
        start:D.start,replacement:"(defun x () 3)"},P),
    assertion(P.status==proposed),assertion(P.tool==project_write),
    assertion(P.arguments.content=="(in-package :demo)\n(defun x () 3)\n(defun y () 2)").

test(prolog_clause_edit,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    Source=":- module(m,[p/1]).\np(a).\np(b).",
    invoke(R,source_inspect_expert,_{language:"prolog",content:Source},A),
    A.definitions=[_,D],
    invoke(R,source_edit_expert,_{language:"prolog",content:Source,path:"test.pl",
        start:D.start,replacement:"p(c)."},P),assertion(P.status==proposed),
    assertion(sub_string(P.arguments.content,_,_,_,"p(a).\np(c).")).

test(block_malformed_replacement,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    invoke(R,source_edit_expert,_{language:"common_lisp",content:"(defun x () 1)",path:"x.lisp",
        start:0,replacement:"(defun x ("},P),assertion(P.status==blocked).

test(block_changed_predicate,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    invoke(R,source_edit_expert,_{language:"prolog",content:"p(a).",path:"x.pl",
        start:0,replacement:"q(a)."},P),assertion(P.status==blocked).

test(compiler_failure_is_not_success,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    invoke(R,compiler_diagnostics_expert,_{language:"prolog",output:"ERROR: x.pl:4:9: Syntax error\n",exit_code:0},D),
    assertion(D.status==failed),D.diagnostics=[First],assertion(First.severity==error),
    assertion(First.line==4),assertion(First.column==9).

test(sbcl_diagnostics,[setup(setup_registry(R)),cleanup(tool_registry_destroy(R))]) :-
    invoke(R,compiler_diagnostics_expert,_{language:"common_lisp",output:"; caught ERROR:\n; bad lambda list\n",exit_code:1},D),
    assertion(D.status==failed),assertion(D.diagnostics=[_|_]).
:- end_tests(language_tools).
