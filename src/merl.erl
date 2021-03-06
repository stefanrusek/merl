%% ---------------------------------------------------------------------
%% Licensed under the Apache License, Version 2.0 (the "License"); you may
%% not use this file except in compliance with the License. You may obtain
%% a copy of the License at <http://www.apache.org/licenses/LICENSE-2.0>
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @author Richard Carlsson <carlsson.richard@gmail.com>
%% @copyright 2010-2013 Richard Carlsson
%% @doc Metaprogramming in Erlang.

-module(merl).

-export([term/1, var/1, print/1, show/1]).

-export([quote/1, quote/2, qquote/2, qquote/3]).

-export([template/1, tree/1, subst/2, tsubst/2, match/2, switch/2]).

-export([template_vars/1, meta_template/1]).

-export([compile/1, compile/2, compile_and_load/1, compile_and_load/2]).

%% NOTE: this module may not include merl.hrl!

-type tree() :: erl_syntax:syntaxTree().

-type tree_or_trees() :: tree() | [tree()].

-type pattern() :: tree() | template().

-type pattern_or_patterns() :: pattern() | [pattern()].

-type env() :: [{Key::id(), pattern_or_patterns()}].

-type id() :: atom() | integer().

%% A list of strings or binaries is assumed to represent individual lines,
%% while a flat string or binary represents source code containing newlines.
-type text() :: string() | binary() | [string()] | [binary()].

-type location() :: erl_scan:location().


%% ------------------------------------------------------------------------
%% Compiling and loading code directly to memory

%% @equiv compile(Code, [])
compile(Code) ->
    compile(Code, []).

%% @doc Compile a syntax tree or list of syntax trees representing a module
%% into a binary BEAM object.
%% @see compile_and_load/2
%% @see compile/1
compile(Code, Options) when not is_list(Code)->
    case type(Code) of
        form_list -> compile(erl_syntax:form_list_elements(Code));
        _ -> compile([Code], Options)
    end;
compile(Code, Options0) when is_list(Options0) ->
    Forms = [erl_syntax:revert(F) || F <- Code],
    Options = [verbose, report_errors, report_warnings, binary | Options0],
    compile:noenv_forms(Forms, Options).


%% @equiv compile_and_load(Code, [])
compile_and_load(Code) ->
    compile_and_load(Code, []).

%% @doc Compile a syntax tree or list of syntax trees representing a module
%% and load the resulting module into memory.
%% @see compile/2
%% @see compile_and_load/1
compile_and_load(Code, Options) ->
    case compile(Code, Options) of
        {ok, ModuleName, Binary} ->
            code:load_binary(ModuleName, "", Binary),
            {ok, Binary};
        Other -> Other
    end.


%% ------------------------------------------------------------------------
%% Utility functions


-spec var(atom()) -> tree().

%% @doc Create a variable.

var(Name) ->
    erl_syntax:variable(Name).


-spec term(term()) -> tree().

%% @doc Create a syntax tree for a constant term.

term(Term) ->
    erl_syntax:abstract(Term).


%% @doc Pretty-print a syntax tree or template to the standard output. This
%% is a utility function for development and debugging.

print(Ts) when is_list(Ts) ->
    lists:foreach(fun print/1, Ts);
print(T) ->
    io:put_chars(erl_prettypr:format(tree(T))),
    io:nl().

%% @doc Print the structure of a syntax tree or template to the standard
%% output. This is a utility function for development and debugging.

show(Ts) when is_list(Ts) ->
    lists:foreach(fun show/1, Ts);
show(T) ->
    io:put_chars(pp(tree(T), 0)),
    io:nl().

pp(T, I) ->
    [lists:duplicate(I, $\s),
     limit(lists:flatten([atom_to_list(type(T)), ": ",
                          erl_prettypr:format(erl_syntax_lib:limit(T,3))]),
           79-I),
     $\n,
     pp_1(lists:filter(fun (X) -> X =/= [] end, subtrees(T)), I+2)
    ].

pp_1([G], I) ->
    pp_2(G, I);
pp_1([G | Gs], I) ->
    [pp_2(G, I), lists:duplicate(I, $\s), "+\n" | pp_1(Gs, I)];
pp_1([], _I) ->
    [].

pp_2(G, I) ->
    [pp(E, I) || E <- G].

%% limit string to N characters, stay on a single line and compact whitespace
limit([$\n | Cs], N) -> limit([$\s | Cs], N);
limit([$\r | Cs], N) -> limit([$\s | Cs], N);
limit([$\v | Cs], N) -> limit([$\s | Cs], N);
limit([$\t | Cs], N) -> limit([$\s | Cs], N);
limit([$\s, $\s | Cs], N) -> limit([$\s | Cs], N);
limit([C | Cs], N) when C < 32 -> limit(Cs, N);
limit([C | Cs], N) when N > 3 -> [C | limit(Cs, N-1)];
limit([_C1, _C2, _C3, _C4 | _Cs], 3) -> "...";
limit(Cs, 3) -> Cs;
limit([_C1, _C2, _C3 | _], 2) -> "..";
limit(Cs, 2) -> Cs;
limit([_C1, _C2 | _], 1) -> ".";
limit(Cs, 1) -> Cs;
limit(_, _) -> [].

%% ------------------------------------------------------------------------
%% Parsing and instantiating code fragments


-spec qquote(Text::text(), Env::env()) -> tree_or_trees().

%% @doc Parse text and substitute meta-variables.
%%
%% @equiv qquote(1, Text, Env)

qquote(Text, Env) ->
    qquote(1, Text, Env).


-spec qquote(StartPos::location(), Text::text(), Env::env()) -> tree_or_trees().

%% @doc Parse text and substitute meta-variables. Takes an initial scanner
%% starting position as first argument.
%%
%% The macro `?Q(Text, Env)' expands to `merl:qquote(?LINE, Text, Env)'.
%%
%% @see quote/2

qquote(StartPos, Text, Env) ->
    subst(quote(StartPos, Text), Env).


-spec quote(Text::text()) -> tree_or_trees().

%% @doc Parse text.
%%
%% @equiv quote(1, Text)

quote(Text) ->
    quote(1, Text).


-spec quote(StartPos::location(), Text::text()) -> tree_or_trees().

%% @doc Parse text. Takes an initial scanner starting position as first
%% argument.
%%
%% The macro `?Q(Text)' expands to `merl:quote(?LINE, Text, Env)'.
%%
%% @see quote/1

quote({Line, Col}, Text)
  when is_integer(Line), is_integer(Col) ->
    quote_1(Line, Col, Text);
quote(StartPos, Text) when is_integer(StartPos) ->
    quote_1(StartPos, undefined, Text).

quote_1(StartLine, StartCol, Text) ->
    %% be backwards compatible as far as R12, ignoring any starting column
    StartPos = case erlang:system_info(version) of
                   "5.6" ++ _ -> StartLine;
                   "5.7" ++ _ -> StartLine;
                   "5.8" ++ _ -> StartLine;
                   _ when StartCol =:= undefined -> StartLine;
                   _ -> {StartLine, StartCol}
               end,
    {ok, Ts, _} = erl_scan:string(flatten_text(Text), StartPos),
    case parse_1(Ts) of
        [T] -> T;
        Other -> Other
    end.

parse_1(Ts) ->
    %% if dot tokens are present, it is assumed that the text represents
    %% complete forms, not dot-terminated expressions or similar
    case split_forms(Ts) of
        {ok, Fs} -> parse_forms(Fs);
        error ->
            parse_2(Ts)
    end.

split_forms(Ts) ->
    split_forms(Ts, [], []).

split_forms([{dot,_}=T|Ts], Fs, As) ->
    split_forms(Ts, [lists:reverse(As, [T]) | Fs], []);
split_forms([T|Ts], Fs, As) ->
    split_forms(Ts, Fs, [T|As]);
split_forms([], Fs, []) ->
    {ok, lists:reverse(Fs)};
split_forms([], [], _) ->
    error;  % no dot tokens found - not representing form(s)
split_forms([], _, [T|_]) ->
    fail("incomplete form after ~p", [T]).

parse_forms([Ts | Tss]) ->
    case erl_parse:parse_form(Ts) of
        {ok, Form} -> [Form | parse_forms(Tss)];
        {error, R} -> parse_error(R)
    end;
parse_forms([]) ->
    [].

parse_2(Ts) ->
    %% one or more comma-separated expressions?
    %% (recall that Ts has no dot tokens if we get to this stage)
    case erl_parse:parse_exprs(Ts ++ [{dot,0}]) of
        {ok, Exprs} -> Exprs;
        {error, E} ->
            parse_3(Ts ++ [{'end',0}, {dot,0}], [E])
    end.

parse_3(Ts, Es) ->
    %% try-clause or clauses?
    case erl_parse:parse_exprs([{'try',0}, {atom,0,true}, {'catch',0} | Ts]) of
        {ok, [{'try',_,_,_,_,_}=X]} ->
            %% get the right kind of qualifiers in the clause patterns
            erl_syntax:try_expr_handlers(X);
        {error, E} ->
            parse_4(Ts, [E|Es])
    end.

parse_4(Ts, Es) ->
    %% fun-clause or clauses? (`(a)' is also a pattern, but `(a,b)' isn't,
    %% so fun-clauses must be tried before normal case-clauses
    case erl_parse:parse_exprs([{'fun',0} | Ts]) of
        {ok, [{'fun',_,{clauses,Cs}}]} -> Cs;
        {error, E} ->
            parse_5(Ts, [E|Es])
    end.

parse_5(Ts, Es) ->
    %% case-clause or clauses?
    case erl_parse:parse_exprs([{'case',0}, {atom,0,true}, {'of',0} | Ts]) of
        {ok, [{'case',_,_,Cs}]} -> Cs;
        {error, E} ->
            %% select the best error to report
            parse_error(lists:last(lists:sort([E|Es])))
    end.

parse_error({L, M, R}) when is_atom(M), is_integer(L) ->
    fail("~w: ~s", [L, M:format_error(R)]);
parse_error({{L,C}, M, R}) when is_atom(M), is_integer(L), is_integer(C) ->
    fail("~w:~w: ~s", [L,C,M:format_error(R)]);
parse_error({_, M, R}) when is_atom(M) ->
    fail(M:format_error(R));
parse_error(R) ->
    fail("unknown parse error: ~p", [R]).

%% ------------------------------------------------------------------------
%% Templates, substitution and matching

%% Leaves are normal syntax trees, and inner nodes are tuples
%% {template,Type,Attrs,Groups} where Groups are lists of lists of nodes.
%% Metavariables are 1-tuples {VarName}, where VarName is an atom or an
%% integer. {'_'} and {0} work as anonymous variables in matching. Glob
%% metavariables are tuples {'*',VarName}, and {'*','_'} and {'*',0} are
%% anonymous globs.

%% Note that although template() :: tree() | ..., it is implied that these
%% syntax trees are free from metavariables, so pattern() :: tree() |
%% template() is in fact a wider type than template().

-type template() :: tree()
                  | {id()}
                  | {'*',id()}
                  | {template, atom(), term(), [[template()]]}.

-type template_or_templates() :: template() | [template()].

-spec template(pattern_or_patterns()) -> template_or_templates().

%% @doc Turn a syntax tree or list of trees into a template or templates.
%% Templates can be instantiated or matched against, and reverted back to
%% normal syntax trees using {@link tree/1}. If the input is already a
%% template, it is not modified further.
%%
%% @see subst/2
%% @see match/2
%% @see tree/1

template(Trees) when is_list(Trees) ->
    [template_0(T) || T <- Trees];
template(Tree) ->
    template_0(Tree).

template_0({template, _, _, _}=Template) -> Template;
template_0({'*',_}=Template) -> Template;
template_0({_}=Template) -> Template;
template_0(Tree) ->
    case template_1(Tree) of
        false -> Tree;
        {Name} when is_list(Name) ->
            fail("bad metavariable: '~s'", [tl(Name)]);  % drop v/n from name
        Template -> Template
    end.

%% returns either a template or a lifted metavariable {String}, or 'false'
%% if Tree contained no metavariables
template_1(Tree) ->
    case subtrees(Tree) of
        [] ->
            case metavar(Tree) of
                {"v_"++Cs}=V when Cs =/= [] -> V;  % to be lifted
                {"n0"++Cs}=V when Cs =/= [] -> V;  % to be lifted
                {"v@"++Cs} when Cs =/= [] -> {'*',list_to_atom(Cs)};
                {"n9"++Cs} when Cs =/= [] -> {'*',list_to_integer(Cs)};
                {"v"++Cs} -> {list_to_atom(Cs)};
                {"n"++Cs} -> {list_to_integer(Cs)};
                false -> false
            end;
        Gs ->
            case template_2(Gs, [], false) of
                Gs1 when is_list(Gs1) ->
                    {template, type(Tree), erl_syntax:get_attrs(Tree), Gs1};
                Other ->
                    Other
            end
    end.

template_2([G | Gs], As, Bool) ->
    case template_3(G, [], false) of
        {"v_"++Cs}=V when Cs =/= [] -> V;  % lift further
        {"n0"++Cs}=V when Cs =/= [] -> V;  % lift further
        {"v@"++Cs} when Cs =/= [] -> {'*',list_to_atom(Cs)};  % stop
        {"n9"++Cs} when Cs =/= [] -> {'*',list_to_integer(Cs)};  % stop
        {"v"++Cs} when is_list(Cs) -> {list_to_atom(Cs)};  % stop
        {"n"++Cs} when is_list(Cs) -> {list_to_integer(Cs)};  % stop
        false -> template_2(Gs, [G | As], Bool);
        G1 -> template_2(Gs, [G1 | As], true)
    end;
template_2([], _As, false) -> false;
template_2([], As, true) -> lists:reverse(As).

template_3([T | Ts], As, Bool) ->
    case template_1(T) of
        {"v_"++Cs} when Cs =/= [] -> {"v"++Cs};  % lift
        {"n0"++Cs} when Cs =/= [] -> {"n"++Cs};  % lift
        false -> template_3(Ts, [T | As], Bool);
        T1 -> template_3(Ts, [T1 | As], true)
    end;
template_3([], _As, false) -> false;
template_3([], As, true) -> lists:reverse(As).


%% @doc Turn a template into a syntax tree representing the template.
%% Meta-variables in the template are turned into normal Erlang variables if
%% their names (after the metavariable prefix characters) begin with an
%% uppercase character. E.g., `_@Foo' in the template becomes the variable
%% `Foo' in the meta-template. Furthermore, variables ending with `@' are
%% automatically wrapped in a call to merl:term/1, so e.g. `_@Foo@ in the
%% template becomes `merl:term(Foo)' in the meta-template.

meta_template(Templates) when is_list(Templates) ->
    [meta_template_1(T) || T <- Templates];
meta_template(Template) ->
    meta_template_1(Template).

meta_template_1({template, Type, Attrs, Groups}) ->
    erl_syntax:tuple(
      [erl_syntax:atom(template),
       erl_syntax:atom(Type),
       erl_syntax:abstract(Attrs),
       erl_syntax:list([erl_syntax:list([meta_template_1(T) || T <- G])
                        || G <- Groups])]);
meta_template_1({Var}=V) ->
    meta_template_2(Var, V);
meta_template_1({'*',Var}=V) ->
    meta_template_2(Var, V);
meta_template_1(Leaf) ->
    erl_syntax:abstract(Leaf).

meta_template_2(Var, V) when is_atom(Var) ->
    case atom_to_list(Var) of
        [C|_]=Name when C >= $A, C =< $Z ; C >= $�, C =< $�, C /= $� ->
            case lists:reverse(Name) of
                "@"++([_|_]=RevRealName) ->  % don't allow empty RealName
                    RealName = lists:reverse(RevRealName),
                    erl_syntax:application(erl_syntax:atom(merl),
                                           erl_syntax:atom(term),
                                           [erl_syntax:variable(RealName)]);
                _ ->
                    %% plain automatic metavariable
                    erl_syntax:variable(Name)
            end;
        _ ->
            erl_syntax:abstract(V)
    end;
meta_template_2(Var, V) when is_integer(Var) ->
    if Var > 9, (Var rem 10) =:= 9 ->
            %% at least 2 digits, ends in 9: make it a Q-variable
            if Var > 99, (Var rem 100) =:= 99 ->
                    %% at least 3 digits, ends in 99: wrap in merl:term/1
                    Name = "Q" ++ integer_to_list(Var div 100),
                    erl_syntax:application(erl_syntax:atom(merl),
                                           erl_syntax:atom(term),
                                           [erl_syntax:variable(Name)]);
               true ->
                    %% plain automatic Q-variable
                    Name = integer_to_list(Var div 10),
                    erl_syntax:variable("Q" ++ Name)
            end;
       true ->
            erl_syntax:abstract(V)
    end.



%% @doc Return an ordered list of the metavariables in the template.

template_vars(Template) ->
    template_vars(Template, []).

template_vars(Templates, Vars) when is_list(Templates) ->
    lists:foldl(fun template_vars_1/2, Vars, Templates);
template_vars(Template, Vars) ->
    template_vars_1(Template, Vars).

template_vars_1({template, _, _, Groups}, Vars) ->
    lists:foldl(fun (G, V) -> lists:foldl(fun template_vars_1/2, V, G) end,
                Vars, Groups);
template_vars_1({Var}, Vars) ->
    ordsets:add_element(Var, Vars);
template_vars_1({'*',Var}, Vars) ->
    ordsets:add_element(Var, Vars);
template_vars_1(_, Vars) ->
    Vars.


-spec tree(template_or_templates()) -> tree_or_trees().

%% @doc Revert a template to a normal syntax tree. Any remaining
%% metavariables are turned into `@'-prefixed atoms or `909'-prefixed
%% integers.
%% @see template/1

tree(Templates) when is_list(Templates) ->
    [tree_1(T) || T <- Templates];
tree(Template) ->
    tree_1(Template).

tree_1({template, Type, Attrs, Groups}) ->
    %% flattening here is needed for templates created via source transforms
    Gs = [lists:flatten([tree_1(T) || T <- G]) || G <- Groups],
    erl_syntax:set_attrs(make_tree(Type, Gs), Attrs);
tree_1({Var}) when is_atom(Var) ->
    erl_syntax:atom(list_to_atom("@"++atom_to_list(Var)));
tree_1({Var}) when is_integer(Var) ->
    erl_syntax:integer(list_to_integer("909"++integer_to_list(Var)));
tree_1({'*',Var}) when is_atom(Var) ->
    erl_syntax:atom(list_to_atom("@@"++atom_to_list(Var)));
tree_1({'*',Var}) when is_integer(Var) ->
    erl_syntax:integer(list_to_integer("9099"++integer_to_list(Var)));
tree_1(Leaf) ->
    Leaf.  % any syntax tree, not necessarily atomic (due to substitutions)


-spec subst(pattern_or_patterns(), env()) -> tree_or_trees().

%% @doc Substitute metavariables in a pattern or list of patterns, yielding
%% a syntax tree or list of trees as result. Both for normal metavariables
%% and glob metavariables, the substituted value may be a single element or
%% a list of elements. For example, if a list representing `1, 2, 3' is
%% substituted for `var' in either of `[foo, _@var, bar]' or `[foo, _@@var,
%% bar]', the result represents `[foo, 1, 2, 3, bar]'.

subst(Trees, Env) when is_list(Trees) ->
    [subst_0(T, Env) || T <- Trees];
subst(Tree, Env) ->
    subst_0(Tree, Env).

subst_0(Tree, Env) ->
    tree_1(subst_1(template(Tree), Env)).


-spec tsubst(pattern_or_patterns(), env()) -> template_or_templates().

%% @doc Like subst/2, but does not convert the result from a template back
%% to a tree. Useful if you want to do multiple separate substitutions.
%% @see subst/2
%% @see tree/2

tsubst(Trees, Env) when is_list(Trees) ->
    [subst_1(template(T), Env) || T <- Trees];
tsubst(Tree, Env) ->
    subst_1(template(Tree), Env).

subst_1({template, Type, Attrs, Groups}, Env) ->
    Gs1 = [lists:flatten([subst_1(T, Env) || T <- G]) || G <- Groups],
    {template, Type, Attrs, Gs1};
subst_1({Var}=V, Env) ->
    case lists:keyfind(Var, 1, Env) of
        {Var, TreeOrTrees} -> TreeOrTrees;
        false -> V
    end;
subst_1({'*',Var}=V, Env) ->
    case lists:keyfind(Var, 1, Env) of
        {Var, TreeOrTrees} -> TreeOrTrees;
        false -> V
    end;
subst_1(Leaf, _Env) ->
    Leaf.


-spec match(pattern_or_patterns(), tree_or_trees()) ->
                   {ok, env()} | error.

%% @doc Match a pattern against a syntax tree (or patterns against syntax
%% trees) returning an environment mapping variable names to subtrees; the
%% environment is always sorted on keys. Note that multiple occurrences of
%% metavariables in the pattern is not allowed, but is not checked.
%%
%% @see template/1
%% @see switch/2

match(Patterns, Trees) when is_list(Patterns), is_list(Trees) ->
    try {ok, match_1(Patterns, Trees, [])}
    catch
        error -> error
    end;
match(Patterns, Tree) when is_list(Patterns) -> match(Patterns, [Tree]);
match(Pattern, Trees) when is_list(Trees) -> match([Pattern], Trees);
match(Pattern, Tree) ->
    try {ok, match_template(template(Pattern), Tree, [])}
    catch
        error -> error
    end.

match_1([P|Ps], [T | Ts], Dict) ->
    match_1(Ps, Ts, match_template(template(P), T, Dict));
match_1([], [], Dict) ->
    Dict;
match_1(_, _, _Dict) ->
    erlang:error(merl_match_arity).

%% match a template against a syntax tree
match_template({template, Type, _, Gs}, Tree, Dict) ->
    case type(Tree) of
        Type -> match_template_1(Gs, subtrees(Tree), Dict);
        _ -> throw(error)  % type mismatch
    end;
match_template({Var}, _Tree, Dict)
  when Var =:= '_' ; Var =:= 0 ->
    Dict;  % anonymous variable
match_template({Var}, Tree, Dict) ->
    orddict:store(Var, Tree, Dict);
match_template(Tree1, Tree2, Dict) ->
    %% if Tree1 is not a template, Tree1 and Tree2 are both syntax trees
    case compare_trees(Tree1, Tree2) of
        true -> Dict;
        false -> throw(error)  % different trees
    end.

match_template_1([G1 | Gs1], [G2 | Gs2], Dict) ->
    match_template_2(G1, G2, match_template_1(Gs1, Gs2, Dict));
match_template_1([], [], Dict) ->
    Dict;
match_template_1(_, _, _Dict) ->
    throw(error).  % shape mismatch

match_template_2([{Var} | Ts1], [_ | Ts2], Dict)
  when Var =:= '_' ; Var =:= 0 ->
    match_template_2(Ts1, Ts2, Dict);  % anonymous variable
match_template_2([{Var} | Ts1], [Tree | Ts2], Dict) ->
    match_template_2(Ts1, Ts2, orddict:store(Var, Tree, Dict));
match_template_2([{'*',Var} | Ts1], Ts2, Dict) ->
    match_glob(lists:reverse(Ts1), lists:reverse(Ts2), Var, Dict);
match_template_2([T1 | Ts1], [T2 | Ts2], Dict) ->
    match_template_2(Ts1, Ts2, match_template(T1, T2, Dict));
match_template_2([], [], Dict) ->
    Dict;
match_template_2(_, _, _Dict) ->
    throw(error).  % shape mismatch

%% match the tails in reverse order; no further globs allowed
match_glob([{'*',Var} | _], _, _, _) ->
    fail("multiple glob variables in same match group: ~w", [Var]);
match_glob([T1 | Ts1], [T2 | Ts2], Var, Dict) ->
    match_glob(Ts1, Ts2, Var, match_template(T1, T2, Dict));
match_glob([], _Group, Var, Dict) when Var =:= '_' ; Var =:= 0 ->
    Dict;  % anonymous glob variable
match_glob([], Group, Var, Dict) ->
    orddict:store(Var, lists:reverse(Group), Dict);
match_glob(_, _, _, _Dict) ->
    throw(error).  % shape mismatch


%% compare two syntax trees for equivalence
compare_trees(T1, T2) ->
    Type1 = type(T1),
    case type(T2) of
        Type1 ->
            case subtrees(T1) of
                [] ->
                    case subtrees(T2) of
                        [] -> compare_leaves(Type1, T1, T2);
                        _Gs2 -> false  % shape mismatch
                    end;
                Gs1 ->
                    case subtrees(T2) of
                        [] -> false;  % shape mismatch
                        Gs2 -> compare_trees_1(Gs1, Gs2)
                    end
            end;
        _Type2 ->
            false  % different tree types
    end.

compare_trees_1([G1 | Gs1], [G2 | Gs2]) ->
    compare_trees_2(G1, G2) andalso compare_trees_1(Gs1, Gs2);
compare_trees_1([], []) ->
    true;
compare_trees_1(_, _) ->
    false.  % shape mismatch

compare_trees_2([T1 | Ts1], [T2 | Ts2]) ->
    compare_trees(T1, T2) andalso compare_trees_2(Ts1, Ts2);
compare_trees_2([], []) ->
    true;
compare_trees_2(_, _) ->
    false.  % shape mismatch

compare_leaves(Type, T1, T2) ->
    case Type of
        atom ->
            erl_syntax:atom_value(T1)
                =:= erl_syntax:atom_value(T2);
        char ->
            erl_syntax:char_value(T1)
                =:= erl_syntax:char_value(T2);
        float ->
            erl_syntax:float_value(T1)
                =:= erl_syntax:float_value(T2);
        integer ->
            erl_syntax:integer_value(T1)
                =:= erl_syntax:integer_value(T2);
        string ->
            erl_syntax:string_value(T1)
                =:= erl_syntax:string_value(T2);
        operator ->
            erl_syntax:operator_name(T1)
                =:= erl_syntax:operator_name(T2);
        text ->
            erl_syntax:text_string(T1)
                =:= erl_syntax:text_string(T2);
        variable ->
            erl_syntax:variable_name(T1)
                =:= erl_syntax:variable_name(T2);
        _ ->
            true  % trivially equal nodes
    end.


%% @doc Match against one or more clauses with patterns and optional guards.
%%
%% Note that clauses following a default action will be ignored.
%%
%% @see match/2

-type switch_clause() ::
          {pattern_or_patterns(), guarded_actions()}
        | {pattern_or_patterns(), guard_test(), switch_action()}
        | default_action().

-type guarded_actions() :: guarded_action() | [guarded_action()].

-type guarded_action() :: switch_action() | {guard_test(), switch_action()}.

-type switch_action() :: fun( (env()) -> any() ).

-type guard_test() :: fun( (env()) -> boolean() ).

-type default_action() :: fun( () -> any() ).


-spec switch(tree_or_trees(), [switch_clause()]) -> any().

switch(Trees, [{Patterns, GuardedActions} | Cs]) when is_list(GuardedActions) ->
    switch_1(Trees, Patterns, GuardedActions, Cs);
switch(Trees, [{Patterns, GuardedAction} | Cs]) ->
    switch_1(Trees, Patterns, [GuardedAction], Cs);
switch(Trees, [{Patterns, Guard, Action} | Cs]) ->
    switch_1(Trees, Patterns, [{Guard, Action}], Cs);
switch(_Trees, [Default | _Cs]) when is_function(Default, 0) ->
    Default();
switch(_Trees, []) ->
    erlang:error(merl_switch_clause);
switch(_Tree, _) ->
    erlang:error(merl_switch_badarg).

switch_1(Trees, Patterns, GuardedActions, Cs) ->
    case match(Patterns, Trees) of
        {ok, Env} ->
            switch_2(Env, GuardedActions, Trees, Cs);
        error ->
            switch(Trees, Cs)
    end.

switch_2(Env, [{Guard, Action} | Bs], Trees, Cs)
  when is_function(Guard, 1), is_function(Action, 1) ->
    case Guard(Env) of
        true -> Action(Env);
        false -> switch_2(Env, Bs, Trees, Cs)
    end;
switch_2(Env, [Action | _Bs], _Trees, _Cs) when is_function(Action, 1) ->
    Action(Env);
switch_2(_Env, [], Trees, Cs) ->
    switch(Trees, Cs);
switch_2(_Env, _, _Trees, _Cs) ->
    erlang:error(merl_switch_badarg).


%% ------------------------------------------------------------------------
%% Internal utility functions

fail(Text) ->
    fail(Text, []).

fail(Fs, As) ->
    throw({error, lists:flatten(io_lib:format(Fs, As))}).

flatten_text([L | _]=Lines) when is_list(L) ->
    lists:foldr(fun(S, T) -> S ++ [$\n | T] end, "", Lines);
flatten_text([B | _]=Lines) when is_binary(B) ->
    lists:foldr(fun(S, T) -> binary_to_list(S) ++ [$\n | T] end, "", Lines);
flatten_text(Text) when is_binary(Text) ->
    binary_to_list(Text);
flatten_text(Text) ->
    Text.

-spec metavar(tree()) -> {string()} | false.

%% Check if a syntax tree represents a metavariable. If not, 'false' is
%% returned; otherwise, this returns a 1-tuple with a string containing the
%% variable name including lift/glob prefixes but without any leading
%% metavariable prefix, and instead prefixed with "v" for a variable or "i"
%% for an integer.
%%
%% Metavariables are atoms starting with @, variables starting with _@,
%% strings starting with "'@, or integers starting with 909. Following the
%% prefix, one or more _ or 0 characters (unless it's the last character in
%% the name) may be used to indicate "lifting" of the variable one or more
%% levels , and after that, a @ or 9 character indicates a glob metavariable
%% rather than a normal metavariable. If the name after the prefix is _ or
%% 0, the variable is treated as an anonymous catch-all pattern in matches.

metavar(Tree) ->
    case type(Tree) of
        atom ->
            case erl_syntax:atom_name(Tree) of
                "@" ++ Cs when Cs =/= [] -> {"v"++Cs};
                _ -> false
            end;
        variable ->
            case erl_syntax:variable_literal(Tree) of
                "_@" ++ Cs when Cs =/= [] -> {"v"++Cs};
                _ -> false
            end;
        integer ->
            case erl_syntax:integer_value(Tree) of
                N when N >= 9090 ->
                    case integer_to_list(N) of
                        "909" ++ Cs -> {"n"++Cs};
                        _ -> false
                    end;
                _ -> false
            end;
        string ->
            case erl_syntax:string_value(Tree) of
                "'@" ++ Cs -> {"v"++Cs};
                _ -> false
            end;
        _ ->
            false
    end.

%% wrappers around erl_syntax functions to provide more uniform shape of
%% generic subtrees (maybe this can be fixed in syntax_tools one day)

type(T) ->
    case erl_syntax:type(T) of
        nil  -> list;
        Type -> Type
    end.

subtrees(T) ->
    case erl_syntax:type(T) of
        tuple ->
            [erl_syntax:tuple_elements(T)];  %% don't treat {} as a leaf
        nil ->
            [[], []];  %% don't treat [] as a leaf, but as a list
        list ->
            case erl_syntax:list_suffix(T) of
                none ->
                    [erl_syntax:list_prefix(T), []];
                S ->
                    [erl_syntax:list_prefix(T), [S]]
            end;
        binary_field ->
            [[erl_syntax:binary_field_body(T)],
             erl_syntax:binary_field_types(T)];
        clause ->
            case erl_syntax:clause_guard(T) of
                none ->
                    [erl_syntax:clause_patterns(T), [],
                     erl_syntax:clause_body(T)];
                G ->
                    [erl_syntax:clause_patterns(T), [G],
                     erl_syntax:clause_body(T)]
            end;
        receive_expr ->
            case erl_syntax:receive_expr_timeout(T) of
                none ->
                    [erl_syntax:receive_expr_clauses(T), [], []];
                E ->
                    [erl_syntax:receive_expr_clauses(T), [E],
                     erl_syntax:receive_expr_action(T)]
            end;
        record_access ->
            case erl_syntax:record_access_type(T) of
                none ->
                    [[erl_syntax:record_access_argument(T)], [],
                     [erl_syntax:record_access_field(T)]];
                R ->
                    [[erl_syntax:record_access_argument(T)], [R],
                     [erl_syntax:record_access_field(T)]]
            end;
        record_expr ->
            case erl_syntax:record_expr_argument(T) of
                none ->
                    [[], [erl_syntax:record_expr_type(T)],
                     erl_syntax:record_expr_fields(T)];
                V ->
                    [[V], [erl_syntax:record_expr_type(T)],
                     erl_syntax:record_expr_fields(T)]
            end;
        record_field ->
            case erl_syntax:record_field_value(T) of
                none ->
                    [[erl_syntax:record_field_name(T)], []];
                V ->
                    [[erl_syntax:record_field_name(T)], [V]]
            end;
        _ ->
            erl_syntax:subtrees(T)
    end.

make_tree(list, [P, []]) -> erl_syntax:list(P);
make_tree(list, [P, [S]]) -> erl_syntax:list(P, S);
make_tree(tuple, [E]) -> erl_syntax:tuple(E);
make_tree(binary_field, [[B], Ts]) -> erl_syntax:binary_field(B, Ts);
make_tree(clause, [P, [], B]) -> erl_syntax:clause(P, none, B);
make_tree(clause, [P, [G], B]) -> erl_syntax:clause(P, G, B);
make_tree(receive_expr, [C, [], _A]) -> erl_syntax:receive_expr(C);
make_tree(receive_expr, [C, [E], A]) -> erl_syntax:receive_expr(C, E, A);
make_tree(record_access, [[E], [], [F]]) -> erl_syntax:record_access(E, F);
make_tree(record_access, [[E], [T], [F]]) -> erl_syntax:record_access(E, T, F);
make_tree(record_expr, [[], [T], F]) -> erl_syntax:record_expr(T, F);
make_tree(record_expr, [[E], [T], F]) -> erl_syntax:record_expr(E, T, F);
make_tree(record_field, [[N], []]) -> erl_syntax:record_field(N);
make_tree(record_field, [[N], [E]]) -> erl_syntax:record_field(N, E);
make_tree(Type, Groups) ->
    erl_syntax:make_tree(Type, Groups).
