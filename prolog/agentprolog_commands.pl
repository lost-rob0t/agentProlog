:- module(agentprolog_commands,[command_head/3,command_space/1]).

% Shared CLI-compatible whitespace, including non-breaking spaces excluded by
% SWI code_type(space) on some platforms. Tail is never normalized.
command_space(C) :- memberchk(C,[9,10,11,12,13,32,160,5760,8192,8193,8194,
    8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288,65279]).
command_head(Text,Head,Tail) :-
    string_codes(Text,Codes),phrase(parts(H,T),Codes),
    string_codes(Head,H),string_codes(Tail,T).
parts(H,T) --> blanks, word(H), {H\=[]}, tail(T).
blanks --> [C],{command_space(C)},!,blanks.
blanks --> [].
word([C|Cs]) --> [C],{\+command_space(C)},!,word(Cs).
word([]) --> [].
tail(T) --> [C],{command_space(C)},!,remainder(T).
tail([]) --> [].
remainder([C|Cs]) --> [C],!,remainder(Cs).
remainder([]) --> [].
