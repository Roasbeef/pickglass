#!/usr/bin/env escript
%%! -name pg_e2e_ctl@127.0.0.1 -setcookie pg_e2e_cookie -hidden
%%% Integration test for the pushed agent.
%%%
%%% Starts a target node and a viewer node as peers, pushes the agent's beams
%%% into the target with `code:load_binary`, starts the agent, and checks the
%%% property the whole design rests on: the agent owns a trace session across
%%% many requests, and when its viewer goes away, whether by a killed link
%%% process or by `kill -9` of the viewer's OS process, the session is
%%% destroyed, `scheduler_wall_time` is released, every agent module is
%%% unloaded, and no process of the target was touched.
%%%
%%% It is an escript rather than a gleeunit test because the test needs
%%% distribution and OS processes: gleeunit runs in a node with neither.
%%% The target peer loads no Gleam module, so the run also shows the agent
%%% works with no dependencies present.
%%%
%%% Usage: escript scripts/agent_e2e.escript <agent ebin directory>
-mode(compile).

main([Ebin]) ->
    process_flag(trap_exit, true),
    Beams = beams(Ebin),
    {ok, TPeer, Target} = peer:start_link(#{name => node_name("pg_e2e_target"),
                                            args => ["-setcookie", "pg_e2e_cookie"]}),
    ok = push(Target, Beams),
    Work = push_workload(Target),
    scenario_link_killed(Target, Work),
    scenario_detach(Target, Work),
    scenario_viewer_killed(Target, Work),
    scenario_attach_again(Target),
    peer:stop(TPeer),
    finish().

%% ---------------------------------------------------------------- scenarios

%% The viewer's link process is killed: the agent must tear everything down.
scenario_link_killed(Target, Work) ->
    heading("link process killed"),
    Link = spawn(fun() -> receive stop -> ok end end),
    Agent = start_agent(Target, Link),
    {<<"pong">>, <<"boot-1">>, _, _, _, _, _} = ask(Target, {<<"ping">>}),
    {<<"memory">>, Cats, _, _, _, _, _} = ask(Target, {<<"memory">>}),
    check("memory reports categories", length(Cats) > 3),
    {<<"census">>, {Scanned, Total, _, _}, Rows, Aggs} =
        ask(Target, {<<"census">>, 100000, 10}),
    check("census scans processes", Scanned > 0 andalso Total > 0),
    check("census returns at most the top 10", length(Rows) >= 1 andalso length(Rows) =< 10),
    check("an unlabelled node aggregates as unknown",
          lists:any(fun({{<<"unknown">>}, _, _, _, _}) -> true; (_) -> false end, Aggs)),
    {<<"pinned">>, <<"boot-1">>, PinId, _} = ask(Target, {<<"pin">>, pid_text(Target, Work)}),
    {<<"scheduler">>, <<"collecting">>, _} = ask(Target, {<<"scheduler">>, <<"on">>}),
    check("scheduler wall time is on", is_list(statistics_on(Target))),
    {<<"counters_started">>, ProbeId, Matched, _} =
        ask(Target, {<<"start_counters">>, <<"pg_e2e_work">>, <<"work">>,
                     {<<"pins">>, [{<<"boot-1">>, PinId}]}, 60000}),
    check("the probe matched a function", Matched >= 1),
    %% The session must survive many requests.
    [ask(Target, {<<"ping">>}) || _ <- lists:seq(1, 300)],
    timer:sleep(300),
    Sessions = sessions(Target),
    check("the session survives 300 requests", length(Sessions) >= 2),
    {<<"counters">>, ProbeId, <<"running">>, _, _, _, CRows} =
        ask(Target, {<<"read_counters">>, ProbeId}),
    check("the probe counted calls to work/1",
          lists:any(fun({<<"pg_e2e_work">>, <<"work">>, 1, Calls, _}) -> Calls > 0;
                       (_) -> false end, CRows)),
    {<<"error">>, <<"unknown_module">>, _} =
        ask(Target, {<<"start_counters">>, <<"zz_no_such_module_ever">>, <<"_">>,
                     {<<"all">>}, 1000}),
    check("an unknown module is refused", true),
    {<<"error">>, <<"bad_request">>, _} = ask(Target, {<<"nonsense">>}),
    check("a malformed request is refused", true),
    check("no atom was created from the unknown module name",
          not atom_exists(Target, <<"zz_no_such_module_ever">>)),
    exit(Link, kill),
    torn_down(Target, Agent, Work, "after the link process died").

%% An explicit detach replies after the session is destroyed.
scenario_detach(Target, Work) ->
    heading("explicit detach"),
    Link = spawn(fun() -> receive stop -> ok end end),
    Agent = start_agent(Target, Link),
    {<<"counters_started">>, _, _, _} =
        ask(Target, {<<"start_counters">>, <<"pg_e2e_work">>, <<"work">>, {<<"all">>}, 60000}),
    check("a probe over all processes is running", length(sessions(Target)) >= 2),
    {<<"detached">>, <<"requested">>} = ask(Target, {<<"detach">>}),
    check("the session is already gone when detach replies", length(sessions(Target)) =:= 1),
    torn_down(Target, Agent, Work, "after detach"),
    exit(Link, kill).

%% The viewer's OS process is killed with SIGKILL. The viewer node starts the
%% agent and owns its link process; the controller issues the requests, since
%% any process may send the agent a request. Killing the viewer's OS process
%% leaves the agent no chance to be told: it learns only from the dead link
%% and the lost connection.
scenario_viewer_killed(Target, Work) ->
    heading("viewer killed with SIGKILL"),
    {ok, _VPeer, V} = peer:start(#{name => node_name("pg_e2e_viewer"),
                                  args => ["-hidden", "-setcookie", "pg_e2e_cookie"]}),
    VLink = erpc:call(V, erlang, spawn, [timer, sleep, [infinity]]),
    {ok, Agent} = erpc:call(V, erpc, call,
                            [Target, pickglass_agent@server, start,
                             [{VLink, <<"boot-2">>, 30000}]]),
    check("the agent started from the viewer node", is_pid(Agent)),
    {<<"scheduler">>, <<"collecting">>, _} = ask(Target, {<<"scheduler">>, <<"on">>}),
    {<<"counters_started">>, _, _, _} =
        ask(Target, {<<"start_counters">>, <<"pg_e2e_work">>, <<"work">>,
                     {<<"all">>}, 60000}),
    check("the viewer's probe is running", length(sessions(Target)) >= 2),
    check("scheduler wall time is on", is_list(statistics_on(Target))),
    Before = erpc:call(Target, erlang, system_info, [process_count]),
    OsPid = erpc:call(V, os, getpid, []),
    _ = os:cmd("kill -9 " ++ OsPid),
    torn_down(Target, Agent, Work, "after kill -9 of the viewer"),
    After = erpc:call(Target, erlang, system_info, [process_count]),
    check("the target kept its processes (" ++ integer_to_list(Before) ++ " -> "
          ++ integer_to_list(After) ++ ")", abs(After - Before) =< 10).

%% After a teardown the node must accept a fresh attach, including one that
%% reloads the modules the previous agent removed.
scenario_attach_again(Target) ->
    heading("re-attach after teardown"),
    %% `torn_down` already pushed a fresh copy of the beams.
    Link = spawn(fun() -> receive stop -> ok end end),
    _ = start_agent(Target, Link),
    {<<"pong">>, _, _, _, _, _, _} = ask(Target, {<<"ping">>}),
    check("the agent answers after a re-attach", true),
    exit(Link, kill),
    wait_until(fun() -> not agent_modules_loaded(Target) end, 5000),
    check("the second agent also unloads", not agent_modules_loaded(Target)).

%% ------------------------------------------------------------------ checks

torn_down(Target, Agent, Work, When) ->
    check("the agent process exits " ++ When,
          wait_until(fun() -> erpc:call(Target, erlang, is_process_alive, [Agent]) =:= false end, 5000)),
    check("every trace session is destroyed " ++ When,
          wait_until(fun() -> length(sessions(Target)) =:= 1 end, 5000)),
    check("scheduler wall time is released " ++ When,
          wait_until(fun() -> statistics_on(Target) =:= undefined end, 5000)),
    check("every pickglass_agent@ module is unloaded " ++ When,
          wait_until(fun() -> not agent_modules_loaded(Target) end, 5000)),
    check("the registered name is free " ++ When,
          erpc:call(Target, erlang, whereis, [pickglass_agent]) =:= undefined),
    check("the target's own process survived " ++ When,
          erpc:call(Target, erlang, is_process_alive, [Work])),
    ok = push(Target, beams(ebin_dir())).

sessions(Target) ->
    erpc:call(Target, trace, session_info, [all]).

statistics_on(Target) ->
    erpc:call(Target, erlang, statistics, [scheduler_wall_time]).

agent_modules_loaded(Target) ->
    [M || {M, _} <- erpc:call(Target, code, all_loaded, []),
          lists:prefix("pickglass_agent@", atom_to_list(M))] =/= [].

atom_exists(Target, Name) ->
    try erpc:call(Target, erlang, binary_to_existing_atom, [Name, utf8]) of
        _ -> true
    catch _:_ -> false
    end.

%% ----------------------------------------------------------------- plumbing

ebin_dir() -> get(ebin).

beams(Ebin) ->
    put(ebin, Ebin),
    [{list_to_atom(filename:basename(F, ".beam")), F}
     || F <- filelib:wildcard(filename:join(Ebin, "pickglass_agent@*.beam")),
        filename:basename(F) =/= "pickglass_agent@@main.beam"].

push(Target, Beams) ->
    lists:foreach(fun({Mod, File}) ->
        {ok, Bin} = file:read_file(File),
        {module, Mod} = erpc:call(Target, code, load_binary, [Mod, File, Bin])
    end, Beams).

start_agent(Target, Link) ->
    {ok, Agent} = erpc:call(Target, pickglass_agent@server, start,
                            [{Link, <<"boot-1">>, 30000}]),
    Agent.

%% Send a request and wait for its reply.
ask(Target, Request) ->
    Ref = make_ref(),
    {pickglass_agent, Target} ! {<<"pg">>, 1, self(), Ref, Request},
    receive
        {<<"pg">>, 1, Ref, Body} -> Body
    after 10000 -> error({no_reply, Request})
    end.

%% The agent reads pids as text local to its own node, which is how the
%% census writes them; a remote pid's own text carries a node index.
%% A full node name on the loopback address, so that every peer is reachable
%% from every other without depending on the host's name resolution.
node_name(Prefix) ->
    Prefix ++ "_" ++ integer_to_list(erlang:unique_integer([positive])) ++ "@127.0.0.1".

pid_text(Target, Pid) ->
    list_to_binary(erpc:call(Target, erlang, pid_to_list, [Pid])).

%% A process on the target that calls a traced function in a loop.
push_workload(Target) ->
    Src = "-module(pg_e2e_work). -export([loop/0, work/1]). "
          "loop() -> work(100), receive after 1 -> ok end, loop(). "
          "work(0) -> ok; work(N) -> lists:sort([3,2,1]), work(N-1). ",
    {ok, Tokens, _} = erl_scan:string(Src),
    Forms = [begin {ok, F} = erl_parse:parse_form(T), F end || T <- split_forms(Tokens)],
    {ok, Mod, Bin} = compile:forms(Forms, [binary]),
    {module, Mod} = erpc:call(Target, code, load_binary, [Mod, "pg_e2e_work.erl", Bin]),
    erpc:call(Target, erlang, spawn, [Mod, loop, []]).

split_forms(Tokens) -> split_forms(Tokens, [], []).
split_forms([], [], Acc) -> lists:reverse(Acc);
split_forms([{dot, _} = D | Rest], Cur, Acc) ->
    split_forms(Rest, [], [lists:reverse([D | Cur]) | Acc]);
split_forms([T | Rest], Cur, Acc) -> split_forms(Rest, [T | Cur], Acc).

wait_until(Fun, Timeout) when Timeout =< 0 -> Fun();
wait_until(Fun, Timeout) ->
    case Fun() of
        true -> true;
        _ -> timer:sleep(50), wait_until(Fun, Timeout - 50)
    end.

heading(Text) -> io:format("~n== ~s~n", [Text]).

check(Name, true) -> io:format("  ok   ~s~n", [Name]), put(passed, get_n(passed) + 1);
check(Name, _) -> io:format("  FAIL ~s~n", [Name]), put(failed, get_n(failed) + 1).

get_n(Key) -> case get(Key) of undefined -> 0; N -> N end.

finish() ->
    Failed = get_n(failed),
    io:format("~n~b checks passed, ~b failed~n", [get_n(passed), Failed]),
    case Failed of 0 -> ok; _ -> halt(1) end.
