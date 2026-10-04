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
    {<<"census">>, {Scanned, Total, _, _}, Rows, Aggs, Totals} =
        ask(Target, {<<"census">>, 100000, 10}),
    check("census scans processes", Scanned > 0 andalso Total > 0),
    check("census returns at most the top 10", length(Rows) >= 1 andalso length(Rows) =< 10),
    check("an unlabelled node aggregates as unknown",
          lists:any(fun({{<<"unknown">>}, _, _, _, _, _}) -> true; (_) -> false end, Aggs)),
    check("the census totals cover every scanned process",
          element(1, Totals) =:= Scanned),
    check("the agent's own processes are their own owner",
          lists:any(fun({{<<"owner">>, [{<<"tool">>, <<"pickglass">>}], <<"agent">>}, _, _, _, _, _}) -> true;
                       (_) -> false end, Aggs)),
    {<<"pinned">>, <<"boot-1">>, PinId, _} = ask(Target, {<<"pin">>, pid_text(Target, Work)}),
    {<<"process_detail">>, DetailPid, {DMem, _, _, _}, {_, _, _, _, _, _},
     {_, _, _, _, _, _, _, _, _}, {_, _, _, _}, _Owner, []} =
        ask(Target, {<<"process_detail">>, {<<"boot-1">>, PinId}}),
    check("process detail reads the pinned process",
          DMem > 0 andalso DetailPid =:= pid_text(Target, Work)),
    {<<"error">>, <<"stale_pin">>, _} =
        ask(Target, {<<"process_detail">>, {<<"boot-1">>, PinId + 100}}),
    check("process detail refuses a pin that does not exist", true),
    {<<"supervision">>, {SScanned, _, <<"finished">>, _}, Edges} =
        ask(Target, {<<"supervision">>, 100000, 10000}),
    WorkText = pid_text(Target, Work),
    check("the supervision walk lists every scanned process", length(Edges) =:= SScanned),
    check("the supervision walk records the workload's spawner",
          lists:any(fun({C, P, _, _, _}) -> C =:= WorkText andalso P =/= <<>>; (_) -> false end,
                    Edges)),
    {<<"system">>, {Uptime, _, _, _, _, _, Scheds, _, _, _, _, _}, Carriers} =
        ask(Target, {<<"system">>}),
    check("the system report has facts", Uptime >= 0 andalso Scheds >= 1),
    check("the system report has carriers or says why not",
          case Carriers of
              {<<"carriers">>, [_ | _]} -> true;
              {<<"unavailable">>, Why} when is_binary(Why) -> true;
              _ -> false
          end),
    {<<"gc">>, <<"intrusive">>, WorkText, <<"completed">>, _,
     {<<"heap">>, _, _, _, _, _, _, _, _, _}, {<<"heap">>, _, _, _, _, _, _, _, _, _}} =
        ask(Target, {<<"gc">>, {<<"boot-1">>, PinId}, 5000}),
    check("a targeted collection reports the heap before and after", true),
    scenario_measure(Target, WorkText),
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
          lists:any(fun({<<"pg_e2e_work">>, <<"work">>, 1, Calls, _, {<<"none">>}}) -> Calls > 0;
                       (_) -> false end, CRows)),
    scenario_counter_set(Target, PinId),
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

%% One probe over two modules, counting allocation as well as time, and the
%% refusals that keep a set from becoming an outage.
scenario_counter_set(Target, PinId) ->
    Pins = {<<"pins">>, [{<<"boot-1">>, PinId}]},
    %% Stop the probe the caller left running so the two-probe limit is free.
    {<<"counters_started">>, SetId, Matched, _} =
        ask(Target, {<<"start_counter_set">>,
                     [{<<"pg_e2e_work">>, <<"_">>}, {<<"pg_e2e_more">>, <<"more">>}],
                     Pins, 60000, <<"time_and_memory">>}),
    check("a counters probe over two modules matches functions of both", Matched >= 2),
    timer:sleep(500),
    {<<"counters">>, SetId, <<"running">>, _, _, {_, _, 0}, Rows} =
        ask(Target, {<<"read_counters">>, SetId}),
    Has = fun(Mod) ->
              lists:any(fun({M, _, _, Calls, _, {<<"words">>, W}}) ->
                                M =:= Mod andalso Calls > 0 andalso W >= 0;
                           (_) -> false end, Rows)
          end,
    check("the rows cover the first module with allocation counted", Has(<<"pg_e2e_work">>)),
    check("the rows cover the second module with allocation counted", Has(<<"pg_e2e_more">>)),
    {<<"counters">>, SetId, _, _, _, _, _} = ask(Target, {<<"stop_counters">>, SetId}),
    {<<"error">>, <<"no_match">>, _} =
        ask(Target, {<<"start_counter_set">>,
                     [{<<"pg_e2e_work">>, <<"work">>}, {<<"pg_e2e_more">>, <<"loop">>}],
                     Pins, 1000, <<"time">>}),
    check("one pattern that matches nothing refuses the set", true),
    {<<"error">>, <<"pattern_too_broad">>, _} =
        ask(Target, {<<"start_counter_set">>,
                     [{<<"pg_e2e_work">>, <<"work">>}, {<<"lists">>, <<"_">>}],
                     Pins, 1000, <<"time">>}),
    check("a wildcard on a hot module inside a set is refused", true),
    check("a refused set leaves no session behind", length(sessions(Target)) =< 2),
    ok.

%% Self-measure: a process that advertises the capability answers, and every
%% way the exchange can go wrong is a typed refusal.
scenario_measure(Target, WorkText) ->
    Good = erpc:call(Target, pg_e2e_measurable, start, [good]),
    Bad = erpc:call(Target, pg_e2e_measurable, start, [bad]),
    Silent = erpc:call(Target, pg_e2e_measurable, start, [silent]),
    Pin = fun(P) ->
              {<<"pinned">>, <<"boot-1">>, Id, _} = ask(Target, {<<"pin">>, pid_text(Target, P)}),
              {<<"boot-1">>, Id}
          end,
    {<<"measure">>, _, _, [{<<"callback">>, 120, <<"words">>}]} =
        ask(Target, {<<"measure">>, Pin(Good), 2000}),
    check("a measurable process answers its own measurement", true),
    {<<"error">>, <<"bad_reply">>, _} = ask(Target, {<<"measure">>, Pin(Bad), 2000}),
    check("a reply that is not readings is refused", true),
    {<<"error">>, <<"measure_deadline">>, _} = ask(Target, {<<"measure">>, Pin(Silent), 200}),
    check("a process that does not answer is a deadline refusal", true),
    {<<"pinned">>, <<"boot-1">>, WId, WorkText} = ask(Target, {<<"pin">>, WorkText}),
    {<<"error">>, <<"not_measurable">>, _} = ask(Target, {<<"measure">>, {<<"boot-1">>, WId}, 500}),
    check("a process that does not advertise measure is not asked", true),
    [exit(P, kill) || P <- [Good, Bad, Silent]],
    ok.

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
    _ = load_source(Target, "pg_e2e_more",
        "-module(pg_e2e_more). -export([more/1]). "
        "more(0) -> ok; more(N) -> lists:reverse([1,2,3]), more(N-1). "),
    Work = load_source(Target, "pg_e2e_work",
        "-module(pg_e2e_work). -export([loop/0, work/1]). "
        "loop() -> work(100), pg_e2e_more:more(3), receive after 1 -> ok end, loop(). "
        "work(0) -> ok; work(N) -> lists:sort([3,2,1]), work(N-1). "),
    _ = load_source(Target, "pg_e2e_measurable",
        "-module(pg_e2e_measurable). -export([start/1]). "
        "start(Mode) -> spawn(fun() -> "
        "  proc_lib:set_label({pickglass_owner, 1, [], <<\"measurable\">>, [<<\"measure\">>]}), "
        "  loop(Mode) end). "
        "loop(Mode) -> receive "
        "  {pickglass_measure, _Budget, ReplyTo, Ref} -> "
        "    case Mode of "
        "      good -> ReplyTo ! {pickglass_measure_reply, Ref, [{<<\"callback\">>, 120, <<\"words\">>}]}; "
        "      bad -> ReplyTo ! {pickglass_measure_reply, Ref, [{<<\"x\">>, <<\"nope\">>, <<\"words\">>}]}; "
        "      silent -> ok "
        "    end, loop(Mode) "
        "end. "),
    erpc:call(Target, erlang, spawn, [Work, loop, []]).

%% Compile a module from source text and load it into the target.
load_source(Target, Name, Src) ->
    {ok, Tokens, _} = erl_scan:string(Src),
    Forms = [begin {ok, F} = erl_parse:parse_form(T), F end || T <- split_forms(Tokens)],
    {ok, Mod, Bin} = compile:forms(Forms, [binary]),
    {module, Mod} = erpc:call(Target, code, load_binary, [Mod, Name ++ ".erl", Bin]),
    Mod.

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
