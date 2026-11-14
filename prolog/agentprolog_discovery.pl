:- module(agentprolog_discovery,[discovery_tools/3,list_files/3,search_files/3]).
/** Opt-in discovery over a host-approved source manifest, not a recursive crawler.
    Hidden/private paths are excluded even when included by the host. */
:- use_module('./agentprolog_workspace_tools',[]).
:- use_module(library(lists)).

discovery_tools(Project,Files,Tools) :-
 absolute_file_name(Project,Root,[file_type(directory),access(read),file_errors(error)]),
 agentprolog_workspace_tools:reject_link_chain(Root),
 (is_list(Files),length(Files,N),N>0,N=<128,maplist(allowed_file,Files),sort(Files,Unique),length(Unique,N)
 -> true ; throw(error(invalid_discovery_manifest,_))),
 maplist(validate_path(Root),Files),
 Tools=[tool(List,agentprolog_discovery:list_files(manifest(Root,Files))),
        tool(Search,agentprolog_discovery:search_files(manifest(Root,Files)))],
 base(workspace_list,"List the explicit host-approved source manifest; not the entire workspace.",List0),
 put_dict(_{arguments:_{type:object,properties:_{},additional_properties:false}},List0,List),
 base(workspace_search,"Literal case-sensitive search of at most 32 host-approved files, 64 matches. Skipped/errors and bounds are not absence proofs.",Search0),
 put_dict(_{arguments:_{type:object,required:[text],properties:_{text:_{type:string}},additional_properties:false}},Search0,Search).
base(Name,Description,tool_schema{name:Name,description:Description,capability:tool(Name),effect:read,
 result:_{type:object},limits:_{time_limit:5.0,max_output_bytes:262144}}).
allowed_file(P) :- string(P),string_length(P,L),L>0,L=<512,
 split_string(P,"/","",Parts),Parts\=[],maplist(allowed_component,Parts),
 last(Parts,Name),string_lower(Name,Lower),
 file_name_extension(_,Ext,Lower),memberchk(Ext,[pl,prolog,js,mjs,cjs,ts,tsx,jsx,py,rs,go,c,h,cpp,hpp,java,md,org,txt,nix]),
 \+ (member(Word,["secret","credential","password","token","private","id_rsa","id_ed25519"]),sub_string(Lower,_,_,_,Word)).
allowed_component(P) :- P\="",\+sub_string(P,0,1,_,"."),
 string_codes(P,Cs),\+ (member(C,Cs),(C<32;C=127;C=92)),
 string_lower(P,L),\+ memberchk(L,["node_modules","vendor","target","dist","build","secrets","credentials","private"]),
 \+ (member(W,["secret","credential","password"]),sub_string(L,_,_,_,W)).
validate_path(Root,P) :- agentprolog_workspace_tools:safe_path(Root,P,_).
list_files(manifest(Root,Files),_,Result) :-
 maplist(list_entry(Root),Files,Entries),
 Result=_{scope:"host_manifest",entries:Entries,complete:true,content_read:false}.
list_entry(Root,P,Entry) :-
 (catch((validate_path(Root,P),agentprolog_workspace_tools:safe_path(Root,P,A),exists_file(A)),E,unavailable(E))
 -> State="available" ; State="unavailable"),Entry=_{path:P,status:State}.
search_files(manifest(Root,Files),Args,Result) :-
 (is_dict(Args),get_dict(text,Args,Q),string(Q),string_length(Q,L),L>0,L=<256
 -> true ; throw(error(invalid_discovery_query,_))),
 take(32,Files,Selected),length(Files,Total),length(Selected,Scanned),
 search_all(Selected,Root,Q,64,Matches,Reports,HitLimit),
 ((Total>Scanned;HitLimit==true) -> Bounded=true ; Bounded=false),
 Result=_{scope:"host_manifest",matches:Matches,files:Reports,budget_exhausted:Bounded,
 manifest_files:Total,selected_files:Scanned,absence_proven:false}.
search_all([],_,_,_,[],[],false).
search_all([P|Ps],Root,Q,Remaining,Matches,[Report|Reports],Hit) :-
 (Remaining=:=0 -> Matches=[],Reports=[],Report=_{path:P,status:"not_scanned_budget"},Hit=true
 ; catch(read_source(Root,P,Text,Hash),E,unavailable(E))
 -> split_string(Text,"\n","",Lines),find_matches(Lines,Q,1,Remaining,Found,More),
    length(Found,N),Left is Remaining-N,
    maplist(with_source(P,Hash),Found,Tagged),
    search_all(Ps,Root,Q,Left,Tail,Reports,Later),append(Tagged,Tail,Matches),
    Report=_{path:P,status:"searched",sha256:Hash},bool_or(More,Later,Hit)
 ; Report=_{path:P,status:"unavailable_or_not_bounded_text"},search_all(Ps,Root,Q,Remaining,Matches,Reports,Hit)).
read_source(Root,P,Text,Hash) :-
 agentprolog_workspace_tools:preflight(Root,read,_{path:P},Snapshot,_),
 agentprolog_workspace_tools:execute(Root,read,Snapshot,Read),Text=Read.content,Hash=Read.sha256.
find_matches([],_,_,_,[],false).
find_matches([L|Ls],Q,Line,Remaining,Matches,More) :-
 Next is Line+1,
 (once(sub_string(L,Start,_,_,Q))
 -> (Remaining=:=0 -> Matches=[],More=true
    ; string_length(L,Length),Begin is max(0,Start-40),Size is min(160,Length-Begin),sub_string(L,Begin,Size,_,Snippet),
      Matches=[_{line:Line,column:Start,snippet:Snippet}|Tail],Left is Remaining-1,
      find_matches(Ls,Q,Next,Left,Tail,More))
 ; find_matches(Ls,Q,Next,Remaining,Matches,More)).
with_source(P,H,X,Y) :- put_dict(_{path:P,sha256:H},X,Y).
bool_or(A,B,R) :- ((A==true;B==true)->R=true;R=false).
take(N,L,T) :- length(L,K),(K=<N->T=L;length(T,N),append(T,_,L)).

% Do not swallow the enclosing tool deadline/cancellation or unexpected failures.
unavailable(error(workspace_error(_),_)) :- !,fail.
unavailable(error(existence_error(_,_),_)) :- !,fail.
unavailable(error(permission_error(_,_,_),_)) :- !,fail.
unavailable(error(representation_error(_),_)) :- !,fail.
unavailable(error(io_error(_,_),_)) :- !,fail.
unavailable(E) :- throw(E).
