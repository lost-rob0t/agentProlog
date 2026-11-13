:- module(agentprolog_example_support,
          [example_file/2, project_root/1, read_only_tools/1, coding_tools/1,
           read_only_capabilities/1, coding_capabilities/1]).

:- use_module('../../prolog/agentprolog_workspace_tools',[workspace_tools/2]).
:- use_module('../../prolog/agentprolog_check_tool',[syntax_check_tool/3]).
:- use_module(library(apply)).

% Resolve bundled files from this source, never from the caller's directory.
example_file(Relative, Absolute) :-
    source_file(agentprolog_example_support:example_file(_,_), Source),
    file_directory_name(Source, Directory),
    absolute_file_name(Relative, Absolute,
        [relative_to(Directory),access(read),file_errors(error)]).

project_root(Root) :-
    (getenv('AGENTPROLOG_EXAMPLE_PROJECT', Path), Path \== ''
     -> true
     ; throw(error(existence_error(environment_variable,'AGENTPROLOG_EXAMPLE_PROJECT'),_))),
    (is_absolute_file_name(Path) -> true
     ; throw(error(domain_error(absolute_project_directory,Path),_))),
    absolute_file_name(Path, Root,
        [file_type(directory),access(write),file_errors(error)]).

read_only_tools(Tools) :-
    project_root(Root), workspace_tools(Root, All),
    include(read_tool, All, Tools).
read_tool(tool(Schema,_)) :- Schema.effect == read.

coding_tools(Tools) :-
    project_root(Root), workspace_tools(Root, Files),
    (getenv('AGENTPROLOG_EXAMPLE_NODE', Node0)
     -> (is_absolute_file_name(Node0) -> true
         ; throw(error(domain_error(absolute_node_executable,Node0),_)))
     ; Node0=path(node)),
    absolute_file_name(Node0, Node, [access(execute),file_errors(error)]),
    syntax_check_tool(Root, Node, Check), append(Files, [Check], Tools).

read_only_capabilities([tool(workspace_read),context(peek)]).
coding_capabilities([tool(workspace_read),tool(workspace_create),
    tool(workspace_write),tool(workspace_modify),tool(workspace_check),context(peek)]).
