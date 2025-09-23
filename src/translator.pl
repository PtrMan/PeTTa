%Flatten (= Head Body) MeTTa function into Prolog Clause:
translate_clause(Input, (Head :- (BodyConj, Out=OutBody))) :- Input = [=, [F|Args0], BodyExpr],
                                                              append(Args0, [Out], Args),
                                                              compound_name_arguments(Head, F, Args),
                                                              translate_expr(BodyExpr, GoalsB, OutBody),
                                                              goals_list_to_conj(GoalsB, BodyConj).

%Conjunction builder, turning goals list to a flat conjunction:
goals_list_to_conj([], true)      :- !.
goals_list_to_conj([G], G)        :- !.
goals_list_to_conj([G|Gs], (G,R)) :- goals_list_to_conj(Gs, R).

%Extract arguments or superpose arguments as list:
arg_to_list([superpose|T], T) :- !.
arg_to_list(A, [A]).

% Runtime dispatcher: call F if it's a registered fun/1, else keep as list:
reduce(F, Args, Out) :- ( nonvar(F), atom(F), fun(F) -> append(Args, [Out], CallArgs),
                                                        Goal =.. [F|CallArgs],
                                                        call(Goal)
                                                      ; Out = [F|Args] ).

%Turn MeTTa code S-expression into goals list:
translate_expr(X, [], X)          :- (var(X) ; atomic(X)), !.
translate_expr([H|T], Goals, Out) :-
        !, translate_expr(H, GsH, HV),
        ( HV == superpose, T = [Args], is_list(Args) -> build_superpose_branches(Args, Out, Branches),
                                                        disj_list(Branches, Disj),
                                                        append(GsH, [Disj], Goals)
        ; HV == collapse, T = [E] -> translate_expr(E, GsE, EV),
                                     goals_list_to_conj(GsE, Conj),
                                     append(GsH, [findall(EV, Conj, Out)], Goals)
        ; HV == if, T = [C, T1, E1] -> translate_expr(C, Gc, Cv),  goals_list_to_conj(Gc, ConC),
                                       translate_expr(T1, Gt, Tv), goals_list_to_conj(Gt, ConT),
                                       translate_expr(E1, Ge, Ev), goals_list_to_conj(Ge, ConE),
                                       ( ConT == true -> BT = (Out = Tv) ; BT = (ConT, Out = Tv) ),
                                       ( ConE == true -> BE = (Out = Ev) ; BE = (ConE, Out = Ev) ),
                                       ( ConC == true -> append(GsH, [ (Cv == true -> BT ; BE) ], Goals)
                                                       ; append(GsH, [ (ConC, (Cv == true -> BT ; BE)) ], Goals) )
        ; HV == case, T = [KeyExpr, PairsExpr] -> translate_expr(KeyExpr, Gk, Kv),
                                                  translate_case(PairsExpr, Kv, Out, IfGoal),
                                                  append(GsH, Gk, G0),
                                                  append(G0, [IfGoal], Goals)
        ; HV == let, T = [Pat, Val, In] -> translate_expr(Pat, Gp, P),
                                           translate_expr(Val, Gv, V),
                                           translate_expr(In,  Gi, I),
                                           Goal = let(P, V, I, Out),
                                           append(GsH, Gp, A), append(A, Gv, B), append(B, Gi, Inner),
                                           Goals = [Goal | Inner]
        ; HV == 'let*', T = [Binds, Body] -> translate_bindings(Binds, Gb, Bs),
                                             translate_expr(Body,  Gd, B),
                                             Goal = 'let*'(Bs, B, Out),
                                             append(GsH, Gb, A), append(A, Gd, Inner),
                                             Goals = [Goal | Inner]
        ; HV == cut, T = [] -> append(GsH, [(!)], Goals),
                               Out = true
        ; ( HV == 'add-atom' ; HV == 'remove-atom' ) -> Out = V,
                                                        append(T, [V], RawArgs),
                                                        Goal =.. [HV|RawArgs],
                                                        append(GsH, [Goal], Goals)
        ; translate_args(T, GsT, AVs),
          append(GsH, GsT, Inner),
          ( atom(HV), fun(HV) -> Out = V,                          %Known function => direct call
                                 append(AVs, [V], ArgsV),
                                 Goal =.. [HV|ArgsV],
                                 append(Inner, [Goal], Goals)
          ; ( number(HV) ; string(HV) ; HV == true ; HV == false ) %Value head, process all tail args
            -> translate_args(AVs, GsTail, AVs1),
               append(Inner, GsTail, Inner1),
               Out = [HV|AVs1],
               Goals = Inner1
          ; is_list(HV) -> eval_data_term(HV, Gd, HV1),            %Plain data list: evaluate inner fun-sublists
                           append(Inner, Gd, Goals),
                           Out = [HV1|AVs]
          ; append(Inner, [reduce(HV, AVs, Out)], Goals) )).       %Unknown head (var/compound) => runtime dispatch

%Handle data list:
eval_data_term(X, [], X) :- (var(X); atomic(X)), !.
eval_data_term([F|As], Goals, Val) :- ( atom(F), fun(F) -> translate_expr([F|As], Goals, Val)
                                                         ; eval_data_list([F|As], Goals, Val) ).

%Handle data list entry:
eval_data_list([], [], []).
eval_data_list([E|Es], Goals, [V|Vs]) :- ( is_list(E) -> eval_data_term(E, G1, V) ; V = E, G1 = [] ),
                                         eval_data_list(Es, G2, Vs),
                                         append(G1, G2, Goals).

%Translate bindings without invoking call:
translate_bindings([], [], []).
translate_bindings([[Pat, Val]|Rest], Goals, [[P,V]|Bs]) :- translate_pattern(Pat, P),  %Handle LHS as pure data
                                                            translate_expr(Val, Gv, V), %RHS as normal expr
                                                            translate_bindings(Rest, Gr, Bs),
                                                            append(Gv, Gr, Goals).

%Patterns: variables, atoms, numbers, lists:
translate_pattern(X, X) :- var(X), !.
translate_pattern(X, X) :- atomic(X), !.
translate_pattern([H|T], [P|Ps]) :- !, translate_pattern(H, P),
                                       translate_pattern(T, Ps).


%Translate case expression recursively into nested if:
translate_case([[K,VExpr]|Rs], Kv, Out, Goal) :- translate_expr(VExpr, Gv, VOut),
                                                 goals_list_to_conj(Gv, ConV),
                                                 Test = (Kv = K),
                                                 ( (ConV == true -> Then = (Out = VOut)
                                                                  ; Then = (ConV, Out = VOut)),
                                                   (Rs == []     -> Goal = (Test -> Then)
                                                                  ; translate_case(Rs, Kv, Out, Next),
                                                                    Goal = (Test -> Then ; Next))).

%Translate arguments recursively:
translate_args([], [], []).
translate_args([X|Xs], Goals, [V|Vs]) :- translate_expr(X, G1, V),
                                         translate_args(Xs, G2, Vs),
                                         append(G1, G2, Goals).

%Build A ; B ; C ... from a list:
disj_list([G], G).
disj_list([G|Gs], (G ; R)) :- disj_list(Gs, R).

%Build one disjunct per branch: (Conj, Out = Val):
build_superpose_branches([], _, []).
build_superpose_branches([E|Es], Out, [B|Bs]) :- translate_expr(E, Gs, Val),
                                                 goals_list_to_conj(Gs, Conj),
                                                 ( Conj == true -> B = (Out = Val)
                                                                 ; B = (Conj, Out = Val) ),
                                                 build_superpose_branches(Es, Out, Bs).
