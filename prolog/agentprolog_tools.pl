:- module(agentprolog_tools, [coding_tools_load/3]).

/** <module> Project-scoped filesystem tools

Root is a trusted host binding, not a model argument. Every write uses the
upstream authority/effect boundary and checks its preimage again at dispatch.
The host must prevent hostile concurrent filesystem namespace mutation.
*/
:- use_module(library(rlm_tool)).
:- use_module(library(rlm_tool_loader)).
:- use_module(library(crypto)).
:- use_module(library(error)).
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(uuid)).
:- use_module(library(rlm_project_source),[extension_language/2]).
:- use_module(agentprolog_language,[]).

coding_tools_load(Registry, Root0, Outcome) :-
    catch(load(Registry, Root0, Outcome), E,
          Outcome = error(coding_tools_error{kind:invalid_project, detail:E})).

load(Registry, Root0, Outcome) :-
    absolute_file_name(Root0, Root,
        [file_type(directory), access(read), file_errors(error)]),
    atomic_list_concat(Segments, '/', Root),
    no_links('/', Segments),
    findall(tool_export{name:N, capability:tool(N), effect:E}, tool(N,E,_), Exports),
    Manifest = tool_pack_manifest{library:agentprolog, category:filesystem, tools:Exports},
    % Root identity is part of the instance identity; a second project cannot
    % silently reuse an already loaded pack with different trusted bindings.
    crypto_data_hash(Root, Hash, [algorithm(sha256)]),
    atom_concat(agentprolog_filesystem_, Hash, Pack),
    rlm_load_tool_pack_instance(Registry, Pack, Manifest,
        agentprolog_tools:register_tools(Root), Outcome).

tool(project_read, read, [path]).
tool(project_analyze, read, [path]).
tool(project_search, read, [path,query]).
tool(project_write, write, [path,expected_sha256,content]).
tool(project_patch, write, [path,expected_sha256,old,new]).

register_tools(Root, Registry, Outcome) :-
    findall(N, tool(N,_,_), Names), register_names(Names, Root, Registry, Outcome).
register_names([], _, _, ok(registered)).
register_names([N|Ns], Root, Registry, Outcome) :-
    tool(N, Effect, Keys),
    findall(K-_{type:string}, member(K,Keys), Pairs),
    dict_pairs(Properties, json, Pairs),
    Schema = tool_schema{name:N, capability:tool(N), effect:Effect,
        description:"Bounded UTF-8 project file operation; writes require exact SHA-256 preimage (missing for create)",
        arguments:_{type:object, required:Keys, additional_properties:false, properties:Properties},
        result:_{type:any}, limits:_{time_limit:5.0, max_output_bytes:524288}},
    tool_register(Registry, Schema,
        tool_handler(agentprolog_tools:preflight(Root,N),
                     agentprolog_tools:execute(Root,N)), Result),
    ( Result = ok(_) -> register_names(Ns, Root, Registry, Outcome)
    ; Outcome = Result ).

preflight(Root, Name, Args, Normalized, Details) :-
    confined_path(Root, Args.path, File),
    prepare(Name, File, Args, Normalized),
    Details = operation_details{project_root:Root, target_path:File}.

prepare(Name, File, Args, Normalized) :-
    ( memberchk(Name,[project_read,project_analyze])
    -> bounded_read(File, _, _), Normalized = Args
    ; Name == project_search
    -> bounded_read(File, _, _), string_length(Args.query, L),
       require(L > 0, empty_search), require(L =< 4096, query_too_large), Normalized = Args
    ; current_content(File, Content, Hash),
      require(Hash == Args.expected_sha256, stale_preimage),
      replacement(Name, Content, Args, New), bounded_content(New),
      Normalized = json{path:Args.path, expected_sha256:Hash, content:New} ).

replacement(project_write, _, Args, Args.content).
replacement(project_patch, Content, Args, New) :-
    require(Args.old \== "", empty_preimage),
    findall(B-A, sub_string(Content, B, _, A, Args.old), Matches),
    require(Matches = [_], ambiguous_or_missing_replacement),
    Matches = [Before-After],
    sub_string(Content, 0, Before, _, Prefix),
    sub_string(Content, _, After, 0, Suffix),
    atomics_to_string([Prefix,Args.new,Suffix], New).

execute(Root, Name, Args, Result) :-
    % Serializes this pack's writes and reads across registries in the process.
    with_mutex(agentprolog_filesystem,
               execute_locked(Root, Name, Args, Result)).

execute_locked(Root, Name, Args, Result) :-
    confined_path(Root, Args.path, File),
    ( Name == project_read
    -> bounded_read(File, Content, Hash),
       Result = json{path:Args.path, content:Content, sha256:Hash}
    ; Name == project_analyze
    -> bounded_read(File,Content,_),file_name_extension(_,Ext,File),
       atom_concat('.',Ext,Extension),
       (extension_language(Extension,Language),memberchk(Language,[prolog,common_lisp])
       -> atom_string(Language,LanguageText),
          agentprolog_language:inspect_source(_{language:LanguageText,content:Content},Analysis),
          Result=Analysis.put(path,Args.path)
       ; throw(error(coding_tool(unsupported_source_language),_)))
    ; Name == project_search
    -> bounded_read(File, Content, Hash),
       split_string(Content, "\n", "", Lines),
       findall(json{line:N,text:Line},
           (nth1(N,Lines,Line), once(sub_string(Line,_,_,_,Args.query))), Matches),
       length(Matches, Count), take(100, Matches, Bounded),
       (Count > 100 -> Truncated = true ; Truncated = false),
       Result = json{path:Args.path, sha256:Hash, matches:Bounded, truncated:Truncated}
    ; current_content(File, _, Hash),
      require(Hash == Args.expected_sha256, stale_preimage),
      atomic_write(Root, Args, File),
      content_hash(Args.content, NewHash),
      Result = json{path:Args.path, sha256:NewHash, previous_sha256:Hash} ).

confined_path(Root, Relative, File) :-
    atomic_list_concat(RootParts, '/', Root), no_links('/', RootParts),
    must_be(string, Relative),
    require(Relative \== "", empty_path),
    require(\+ sub_string(Relative,0,1,_,"/"), absolute_path),
    require(\+ sub_string(Relative,_,_,_,"\\"), backslash_path),
    require(\+ sub_string(Relative,_,_,_,"\u0000"), nul_path),
    split_string(Relative,"/","",Parts),
    maplist(safe_segment, Parts),
    no_links(Root, Parts),
    atom_string(Rel, Relative), directory_file_path(Root, Rel, File),
    file_directory_name(File, Parent),
    require(exists_directory(Parent), missing_parent).

safe_segment(P) :- require(\+ memberchk(P,["",".","..",".git"]), invalid_segment).
no_links(_, []).
no_links(Parent, [P|Ps]) :-
    ( P == '' -> Child = Parent
    ; directory_file_path(Parent, P, Child),
      require(\+ read_link(Child,_,_), symlink_denied) ),
    no_links(Child, Ps).

current_content(File, Content, Hash) :-
    ( exists_file(File) -> bounded_read(File, Content, Hash)
    ; require(\+ exists_directory(File), not_regular_file),
      Content = "", Hash = "missing" ).

bounded_read(File, Content, Hash) :-
    require(exists_file(File), missing_file),
    regular_mode(File, _),
    size_file(File, Bytes), require(Bytes =< 65536, file_too_large),
    setup_call_cleanup(open(File, read, S, [type(binary)]),
                       read_string(S, 65537, Raw), close(S)),
    string_codes(Raw, Octets), string_bytes(Content, Octets, utf8),
    require(\+ sub_string(Content,_,_,_,"\u0000"), binary_file),
    bounded_content(Content), content_hash(Content, Hash).

bounded_content(Content) :-
    must_be(string, Content), string_bytes(Content, Bytes, utf8),
    length(Bytes, Size), require(Size =< 65536, file_too_large).
content_hash(Content, Hash) :-
    crypto_data_hash(Content, Atom, [algorithm(sha256),encoding(utf8)]), atom_string(Atom, Hash).

atomic_write(Root, Args, File) :-
    file_directory_name(File, Parent), uuid(UUID),
    atom_concat('.agentprolog-', UUID, Name), directory_file_path(Parent, Name, TempDir),
    % mkdir is exclusive; the temporary file stays on the target filesystem.
    setup_call_cleanup(make_directory(TempDir),
        ( directory_file_path(TempDir, content, Temp),
          setup_call_cleanup(open(Temp, write, S, [encoding(utf8)]),
                             format(S, '~s', [Args.content]), close(S)),
          ( exists_file(File) -> regular_mode(File, Mode) ; Mode = 0o600 ),
          chmod(Temp, Mode),
          confined_path(Root, Args.path, File),
          current_content(File, _, Current),
          require(Current == Args.expected_sha256, stale_preimage),
          ( Current == "missing"
          -> link_file(Temp, File, hard)
          ; rename_file(Temp, File) ) ),
        delete_directory_and_contents(TempDir)).

take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [X|Xs], [X|Ys]) :- N1 is N-1, take(N1, Xs, Ys).
require(Goal, Reason) :- (call(Goal) -> true ; throw(error(coding_tool(Reason), _))).

% SWI filesex has no exported stat accessor. Isolate its POSIX native accessor
% here; the integration tests exercise this supported-runtime dependency.
regular_mode(File, Permissions) :-
    files_ex:file_mode_(File, Mode),
    require(Mode /\ 0o170000 =:= 0o100000, not_regular_file),
    Permissions is Mode /\ 0o777.
