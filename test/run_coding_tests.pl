:- set_prolog_flag(on_error, status).
:- use_module(library(plunit)).
:- consult(coding_tools_test).
:- consult(language_tools_test).
:- initialization(main, main).
main(_) :- (run_tests([coding_tools,language_tools]) -> halt(0); halt(1)).
