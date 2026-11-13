:- use_module('./agentprolog_skills').
:- initialization(main,main).
main([Root,Output]) :- import_markdown(Root,Output), !.
main(_) :- format(user_error,'Usage: agentprolog-import-skill SKILL_ROOT OUTPUT.pl~n',[]),halt(2).
