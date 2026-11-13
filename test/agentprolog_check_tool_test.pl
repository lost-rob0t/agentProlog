:- begin_tests(agentprolog_check_tool).
:- use_module('../prolog/agentprolog_check_tool').
:- use_module(library(filesex)).
:- use_module(library(process)).

root(R) :- tmp_file(syntax_tool,R),make_directory(R).
cleanup(R) :- delete_directory_and_contents(R).
source(R,Text) :- directory_file_path(R,'app.mjs',P),
    setup_call_cleanup(open(P,write,S),format(S,'~s',[Text]),close(S)).
node(Node) :- absolute_file_name(path(node),Node,[access(execute)]).
check(R,Result) :- node(Node),preflight(R,_{path:"app.mjs"},Args,_),execute(R,Node,Args,Result).
test(valid_program_is_checked_not_executed,[setup(root(R)),cleanup(cleanup(R))]) :-
    source(R,"throw new Error('MUST_NOT_EXECUTE');"),check(R,Result),assertion(Result.exit_code==0).
test(syntax_error_returns_observed_failure,[setup(root(R)),cleanup(cleanup(R))]) :-
    source(R,"export function invalid( {"),check(R,Result),assertion(Result.exit_code \== 0),
    assertion(sub_string(Result.output,_,_,_,"SyntaxError")).
test(path_escape_denied,[setup(root(R)),cleanup(cleanup(R)),throws(error(workspace_error(invalid_path),_))]) :-
    preflight(R,_{path:"../outside.mjs"},_,_).
:- end_tests(agentprolog_check_tool).
