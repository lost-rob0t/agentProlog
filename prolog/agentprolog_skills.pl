:- module(agentprolog_skills,[load_skill_units/2,import_markdown/2]).

/** Inert native serialization of the upstream prompt_unit IR. Never consult it. */
:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(library(crypto)).
:- use_module(library(uuid)).
:- use_module(library(rlm_skill)).
:- use_module(library(rlm_prompt_compiler)).
:- use_module(library(rlm_effect),[rlm_effect_normalize/2]).

load_skill_units(Files,Units) :-
    must_be(list,Files),length(Files,N),check(N =< 64,too_many_files),
    maplist(load_units_file,Files,Groups),append(Groups,Units),
    length(Units,Count),check(Count =< 128,too_many_skills),
    findall(Name,(member(U,Units),Name=U.unit),Names),sort(Names,Unique),
    length(Unique,Count), !.
load_skill_units(_,_) :- throw(error(agentprolog_skills(duplicate_skill),_)).

load_units_file(Path,Units) :-
    size_file(Path,Size),check(Size =< 1048576,file_too_large(Path)),
    setup_call_cleanup(open(Path,read,S,[encoding(utf8)]),
      (read_term(S,Term,[syntax_errors(error)]),read_term(S,End,[syntax_errors(error)])),close(S)),
    check((Term=agentprolog_skills(Raw),is_list(Raw),End==end_of_file),invalid_document(Path)),
    crypto_file_hash(Path,Hash,[algorithm(sha256)]),
    maplist(native_unit(Path,Hash),Raw,Units),
    setup_call_cleanup(prompt_catalog_create(C),maplist(register_unit(C),Units),prompt_catalog_destroy(C)).

native_unit(Path,Hash,Raw,Unit) :-
    check(is_dict(Raw),expected_prompt_unit),
    check((get_dict(unit,Raw,skill(Name)),atom(Name)),expected_skill_unit),
    check((get_dict(content,Raw,Body),string(Body)),expected_content),
    string_bytes(Body,Bytes,utf8),length(Bytes,Length),check(Length =< 32768,body_too_large(Name)),
    check((\+ get_dict(mandatory_context,Raw,true)),forbidden_policy(mandatory_context)),
    check((\+ get_dict(activation,Raw,always)),forbidden_policy(activation)),
    (get_dict(provenance,Raw,Original) -> term_string(Original,Prior) ; Prior="native"),
    format(string(Provenance),'native(~w,sha256:~w,source:~s)',[Path,Hash,Prior]),
    put_dict(_{kind:skill,mandatory_context:false,provider_visible:true,provenance:Provenance},Raw,U),
    rlm_effect_normalize(U,Unit).

register_unit(C,Unit) :-
    prompt_catalog_register(C,Unit,Result),require_ok(Result,_).
require_ok(ok(Value),Value) :- !.
require_ok(error(Error),_) :- throw(error(agentprolog_skills(compiler(Error)),_)).
check(Goal,Code) :- (call(Goal) -> true ; throw(error(agentprolog_skills(Code),_))).

import_markdown(Root,Output) :-
    skill_catalog_load([skill_root(markdown_import,Root)],[],Result),require_ok(Result,Catalog),
    skill_catalog_skills(Catalog,Skills),check(Skills \== [],no_skills_found),
    maplist(import_unit,Skills,Units),
    file_directory_name(Output,Parent),uuid(UUID),
    atomic_list_concat(['.agentprolog-skill-',UUID],Name),directory_file_path(Parent,Name,Temporary),
    setup_call_cleanup(open(Temporary,write,S,[encoding(utf8)]),
      (write_term(S,agentprolog_skills(Units),[quoted(true),fullstop(true),nl(true)]),
       close(S),link_file(Temporary,Output,hard)),
      (catch(close(S),_,true), (exists_file(Temporary) -> delete_file(Temporary) ; true))).
import_unit(Skill,Unit) :-
    skill_prompt_unit(Skill,[],Result),require_ok(Result,U),
    directory_file_path(Skill.directory,'SKILL.md',Source),
    format(string(Provenance),'markdown(~w,~w)',[Source,Skill.fingerprint]),
    put_dict(provenance,U,Provenance,WithSource),rlm_effect_normalize(WithSource,Unit).
