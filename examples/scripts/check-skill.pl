:- use_module('../../prolog/agentprolog_skills', [load_skill_units/2]).
:- initialization(main, main).

main([Path]) :- load_skill_units([Path], [_|_]), !.
main(_) :- format(user_error, 'Expected one nonempty native skill file~n', []), halt(2).
