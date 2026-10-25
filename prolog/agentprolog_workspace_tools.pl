:- module(agentprolog_workspace_tools,
          [workspace_tools/2, preflight/5, execute/4]).

/** Bounded file tools for an explicitly trusted, isolated workspace.

Register the returned tool_handler terms through rlm_tool. Preflight runs before
native authority mediation; mutations retain effect:write and never grant their
own approval. Revalidation at execution catches changes while approval is pending.
This is not an OS sandbox against a hostile process concurrently replacing paths.
*/
:- use_module(library(crypto)).
:- use_module(library(readutil)).
:- use_module(library(filesex)).
:- use_module(library(uuid)).
:- use_module(library(lists)).

max_file_bytes(65536).

workspace_tools(Root0, Tools) :-
    absolute_file_name(Root0, Root, [file_type(directory), access(write), file_errors(error)]),
    reject_link_chain(Root),
    findall(tool(Schema, tool_handler(agentprolog_workspace_tools:preflight(Root, Operation),
                                     agentprolog_workspace_tools:execute(Root, Operation))),
            schema(Operation, Schema), Tools).

schema(Operation, Schema) :-
    operation(Operation, Name, Description, Effect, Required, Properties),
    (Operation == read
    -> ResultProperties = _{path:_{type:string},content:_{type:string},sha256:_{type:string},bytes:_{type:integer}},
       ResultRequired = [path,content,sha256,bytes]
    ; ResultProperties = _{path:_{type:string},sha256:_{type:string},bytes:_{type:integer}},
      ResultRequired = [path,sha256,bytes]),
    Schema = tool_schema{name:Name, description:Description, capability:tool(Name), effect:Effect,
        arguments:_{type:object, required:Required, additional_properties:false, properties:Properties},
        result:_{type:object, required:ResultRequired, additional_properties:false, properties:ResultProperties},
        limits:_{time_limit:3.0,max_output_bytes:400000}}.
operation(read, workspace_read, "Read one bounded UTF-8 workspace file and its SHA-256", read,
          [path], _{path:_{type:string}}).
operation(create, workspace_create, "Create one new bounded UTF-8 workspace file; never overwrite", write,
          [path,content], _{path:_{type:string},content:_{type:string}}).
operation(write, workspace_write, "Atomically replace a workspace file only if its SHA-256 still matches", write,
          [path,content,expected_sha256], _{path:_{type:string},content:_{type:string},expected_sha256:_{type:string}}).
operation(modify, workspace_modify, "Replace exactly one occurrence in a workspace file with SHA-256 conflict detection", write,
          [path,old_text,new_text,expected_sha256],
          _{path:_{type:string},old_text:_{type:string},new_text:_{type:string},expected_sha256:_{type:string}}).

preflight(Root, Operation, Args, Normalized, Details) :-
    safe_path(Root, Args.path, Absolute),
    inspect(Operation, Absolute, Args, Before, Content),
    content_bytes(Content, Bytes),
    max_file_bytes(Max), check(Bytes =< Max, file_too_large),
    Normalized = _{path:Args.path,absolute:Absolute,before:Before,content:Content},
    Details = _{target_path:Absolute,project_root:Root,operation:Operation,
                expected_sha256:Before,bytes:Bytes}.

execute(Root, Operation, Args, Result) :-
    with_mutex(agentprolog_workspace_files,
        execute_locked(Root, Operation, Args, Result)).
execute_locked(Root, Operation, Args, Result) :-
    safe_path(Root, Args.path, Absolute),
    check(Absolute == Args.absolute, path_changed),
    ( Operation == read
    -> read_bounded(Absolute, Content, Hash),
       check(Hash == Args.before, stale_content),
       content_bytes(Content, Bytes),
       Result = _{path:Args.path,content:Content,sha256:Hash,bytes:Bytes}
    ; (Operation == create
      -> check(\+ exists_file(Absolute), already_exists), check(\+ exists_directory(Absolute), already_exists)
      ; read_bounded(Absolute, _, Current), check(Current == Args.before, stale_content)),
      atomic_content(Absolute, Args.content, Operation),
      hash_text(Args.content, Hash), content_bytes(Args.content, Bytes),
      Result = _{path:Args.path,sha256:Hash,bytes:Bytes}
    ).

inspect(read, Path, _, Hash, Content) :- !, read_bounded(Path, Content, Hash).
inspect(create, Path, Args, "absent", Content) :- !,
    check(\+ exists_file(Path), already_exists), check(\+ exists_directory(Path), already_exists),
    require_text(Args.content, Content).
inspect(write, Path, Args, Hash, Content) :- !,
    read_bounded(Path, _, Hash), require_text(Args.expected_sha256, Expected),
    check(Hash == Expected, stale_content), require_text(Args.content, Content).
inspect(modify, Path, Args, Hash, Content) :- !,
    read_bounded(Path, Before, Hash), require_text(Args.expected_sha256, Expected),
    check(Hash == Expected, stale_content), require_text(Args.old_text, Old), require_text(Args.new_text, New),
    check(Old \== "", empty_match),
    findall(Pos, sub_string(Before, Pos, _, _, Old), Positions),
    check(Positions = [_], non_unique_match), Positions = [Pos],
    string_length(Old, OldLength), Start is Pos + OldLength,
    sub_string(Before, 0, Pos, _, Prefix), sub_string(Before, Start, _, 0, Suffix),
    string_concat(Prefix, New, First), string_concat(First, Suffix, Content).

safe_path(Root, Relative, Absolute) :-
    require_text(Relative, Text), check(Text \== "", invalid_path),
    check(\+ sub_string(Text,0,1,_,"/"), invalid_path),
    check(\+ sub_string(Text,_,_,_,"\\"), invalid_path),
    string_codes(Text, Codes), check(\+ (member(C,Codes), C < 32), invalid_path),
    split_string(Text,"/","", Parts),
    check(\+ (member(P,Parts), memberchk(P,["",".",".."])), invalid_path),
    reject_link_chain(Root),
    fold_path(Parts, Root, Absolute),
    file_directory_name(Absolute, Parent), check(exists_directory(Parent), missing_parent),
    check(\+ exists_directory(Absolute), not_regular_file).
fold_path([], Path, Path).
fold_path([Segment|Rest], Parent, Path) :-
    atom_string(Atom, Segment), directory_file_path(Parent,Atom,Next),
    check(\+ read_link(Next,_,_), symlink_denied), fold_path(Rest,Next,Path).
reject_link_chain('/') :- !.
reject_link_chain(Path) :-
    check(\+ read_link(Path,_,_), symlink_denied),
    file_directory_name(Path, Parent),
    (Parent == Path -> true ; reject_link_chain(Parent)).

read_bounded(Path, Content, Hash) :-
    check(exists_file(Path), missing_file),
    absolute_file_name(Path, _, [file_type(regular),access(read),file_errors(error)]),
    size_file(Path, Size), max_file_bytes(Max), check(Size =< Max, file_too_large),
    Limit is Max+1,
    setup_call_cleanup(open(Path,read,S,[encoding(utf8)]), read_string(S,Limit,Content),close(S)),
    content_bytes(Content, Bytes), check(Bytes =< Max, file_too_large), hash_text(Content,Hash).
require_text(Text, Text) :- check(string(Text), invalid_text).
content_bytes(Text, Bytes) :- string_bytes(Text,Codes,utf8), length(Codes,Bytes).
hash_text(Text, Hash) :- crypto_data_hash(Text,Atom,[algorithm(sha256),encoding(utf8)]), atom_string(Atom,Hash).
check(Goal, Code) :- (call(Goal) -> true ; throw(error(workspace_error(Code),_))).

atomic_content(Path, Content, Operation) :-
    file_directory_name(Path, Parent), uuid(UUID),
    atom_concat('.agentprolog-write-',UUID,Name), directory_file_path(Parent,Name,Temporary),
    setup_call_cleanup(
      open(Temporary,write,Stream,[encoding(utf8),create([read,write])]),
      (format(Stream,'~s',[Content]), flush_output(Stream), close(Stream),
       (Operation == create
       -> link_file(Temporary,Path,hard), delete_file(Temporary)
       ; rename_file(Temporary,Path))),
      (catch(close(Stream),_,true), (exists_file(Temporary)->delete_file(Temporary);true))).
