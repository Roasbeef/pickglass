#!/usr/bin/env escript
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
    %% The controller's name is unique per run, so two runs on one machine,
    %% such as checks in two worktrees, do not collide on a fixed name.
    {ok, _} = net_kernel:start(list_to_atom(node_name("pg_e2e_ctl")),
                               #{name_domain => longnames, hidden => true}),
    erlang:set_cookie(node(), pg_e2e_cookie),
    process_flag(trap_exit, true),
    Beams = beams(Ebin),
    {ok, TPeer, Target} = peer:start_link(#{name => node_name("pg_e2e_target"),
                                            args => ["-setcookie", "pg_e2e_cookie"]}),
    ok = push(Target, Beams),
    Work = push_workload(Target),
    scenario_link_killed(Target, Work),
    scenario_detach(Target, Work),
    scenario_viewer_killed(Target, Work),
    scenario_viewer_killed_tracing(Target, Work),
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
    {<<"census">>, {Scanned, Total, _, _}, Rows, LegacyAggs} =
        ask(Target, {<<"census">>, 100000, 10}),
    check("the census keeps its first-release shape: five-field owners",
          lists:all(fun({_, _, _, _, _}) -> true; (_) -> false end, LegacyAggs)),
    {<<"owners">>, {OScanned, _, _, _}, ORows, Aggs, Totals} =
        ask(Target, {<<"owners">>, 100000, 10}),
    check("owners returns the census rows", length(ORows) >= 1 andalso length(ORows) =< 10),
    check("census scans processes", Scanned > 0 andalso Total > 0),
    check("census returns at most the top 10", length(Rows) >= 1 andalso length(Rows) =< 10),
    check("an unlabelled node aggregates as unknown",
          lists:any(fun({{<<"unknown">>}, _, _, _, _, _}) -> true; (_) -> false end, Aggs)),
    check("the census totals cover every scanned process",
          element(1, Totals) =:= OScanned),
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
    scenario_ets(Target),
    scenario_binaries(Target),
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
    scenario_counter_set(Target, PinId),
    scenario_stacks(Target, PinId),
    scenario_calltrace(Target, PinId),
    scenario_events(Target, PinId),
    scenario_trace_floods(Target),
    {<<"error">>, <<"unknown_module">>, _} =
        ask(Target, {<<"start_counters">>, <<"zz_no_such_module_ever">>, <<"_">>,
                     {<<"all">>}, 1000}),
    check("an unknown module is refused", true),
    {<<"error">>, <<"bad_request">>, _} = ask(Target, {<<"nonsense">>}),
    check("a malformed request is refused", true),
    check("no atom was created from the unknown module name",
          not atom_exists(Target, <<"zz_no_such_module_ever">>)),
    {<<"events_started">>, _, _, _, _, _, _, _} =
        ask(Target, {<<"start_events">>, [{<<"boot-1">>, PinId}], 60000, 200000, 100, 0, 0}),
    check("an events probe is running when the link process is killed",
          length(sessions(Target)) >= 3),
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
    {<<"counter_memory">>, SetId, <<"running">>, {<<"words">>, MemRows}} =
        ask(Target, {<<"read_counter_memory">>, SetId}),
    Has = fun(Mod, Which) ->
              lists:any(fun({M, _, _, Calls, _}) -> M =:= Mod andalso Calls > 0 end, Which)
          end,
    HasWords = fun(Mod) ->
                   lists:any(fun({M, _, _, W}) -> M =:= Mod andalso W >= 0 end, MemRows)
               end,
    check("the time rows cover the first module", Has(<<"pg_e2e_work">>, Rows)),
    check("the time rows cover the second module", Has(<<"pg_e2e_more">>, Rows)),
    check("the allocation rows cover the first module", HasWords(<<"pg_e2e_work">>)),
    check("the allocation rows cover the second module", HasWords(<<"pg_e2e_more">>)),
    {<<"counters">>, SetId, _, _, _, _, _} = ask(Target, {<<"stop_counters">>, SetId}),
    {<<"counter_memory">>, _, _, {<<"none">>}} = ask_time_only_memory(Target, Pins),
    check("a time-only probe answers none for allocation, not zeros", true),
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
    {<<"counters_started">>, PrefixId, PrefixMatched, _} =
        ask(Target, {<<"start_counter_set">>, [{<<"pg_e2e_*">>, <<"_">>}], Pins, 60000, <<"time">>}),
    check("a counters probe over a module prefix matches the functions of every module",
          PrefixMatched >= Matched),
    {<<"counters">>, PrefixId, _, _, _, _, _} = ask(Target, {<<"stop_counters">>, PrefixId}),
    {<<"error">>, <<"unknown_function">>, _} =
        ask(Target, {<<"start_counter_set">>, [{<<"pg_e2e_*">>, <<"work">>}], Pins, 1000, <<"time">>}),
    check("a module prefix takes only every function", true),
    check("a refused set leaves no session behind", length(sessions(Target)) =< 2),
    ok.

%% The stack sampling probe: it samples a pinned process, ends itself at its
%% deadline, aggregates identical stacks in the agent, and counts toward the
%% two-probe limit while it runs.
scenario_stacks(Target, PinId) ->
    Pin = {<<"boot-1">>, PinId},
    {<<"stacks_started">>, Id, 1, 200, 1000, 100000} =
        ask(Target, {<<"start_stacks">>, [Pin], 200, 1000, 100000}),
    check("a stack probe starts and echoes its clamped parameters", true),
    {<<"error">>, <<"probe_limit">>, _} =
        ask(Target, {<<"start_stacks">>, [Pin], 100, 1000, 1000}),
    check("a second stack probe is refused while one is sampling", true),
    {<<"error">>, <<"probe_limit">>, _} =
        ask(Target, {<<"start_counters">>, <<"pg_e2e_work">>, <<"work">>, {<<"all">>}, 1000}),
    check("the two-probe limit counts a stack probe", true),
    {<<"pong">>, _, _, _, _, _, Running} = ask(Target, {<<"ping">>}),
    check("ping counts the running stack probe", Running >= 2),
    timer:sleep(400),
    {<<"stacks">>, Id, <<"running">>, <<"running">>, {_, _, _, _, Mid, _, _, _, _, _, _, _}, _, _} =
        ask(Target, {<<"read_stacks">>, Id}),
    check("a running probe can be read and has samples", Mid > 0),
    timer:sleep(1200),
    {<<"stacks">>, Id, <<"finished">>, <<"deadline">>,
     {<<"polled_current_stacktrace">>, 200, Milli, Rounds, Samples, Elapsed, Depth,
      _AtDepth, 0, 0, Distinct, 0}, Frames, Stacks} =
        ask(Target, {<<"read_stacks">>, Id}),
    io:format("       stack probe: ~b samples in ~b ms, ~b mHz achieved, depth limit ~b, ~b stacks~n",
              [Samples, Elapsed, Milli, Depth, Distinct]),
    check("the probe stopped at its deadline", Elapsed >= 950 andalso Elapsed =< 1600),
    check("the probe sampled about as often as asked",
          Rounds >= 100 andalso Samples =:= Rounds),
    check("the probe measured the node's backtrace depth", Depth >= 1 andalso Depth =< 256),
    check("identical stacks are aggregated in the agent",
          Distinct =:= length(Stacks) andalso Distinct >= 1 andalso Distinct < Samples),
    check("the counts account for every sample",
          lists:sum([C || {C, _, _} <- Stacks]) =:= Samples),
    check("the stacks name the workload's function",
          lists:any(fun({<<"pg_e2e_work">>, _, _, _}) -> true;
                       ({<<"lists">>, _, _, _}) -> true;
                       (_) -> false end, Frames)),
    check("every frame index is in the table",
          lists:all(fun({_, _, Is}) -> lists:all(fun(I) -> I >= 0 andalso I < length(Frames) end, Is) end,
                    Stacks)),
    {<<"stacks">>, Id, <<"finished">>, <<"deadline">>, _, _, _} =
        ask(Target, {<<"stop_stacks">>, Id}),
    check("stopping a finished probe returns its result", true),
    {<<"error">>, <<"no_such_probe">>, _} = ask(Target, {<<"read_stacks">>, Id}),
    check("a stopped probe is gone", true),
    ok.

%% The call tree probe: it folds events into paths in the tracer, stops at its
%% window and at its event budget, and its paths are the shape the stack probe
%% uses, with call counts and inclusive and exclusive time.
scenario_calltrace(Target, PinId) ->
    heading("call tree probe"),
    Pin = {<<"boot-1">>, PinId},
    Patterns = [{<<"pg_e2e_work">>, <<"_">>}, {<<"pg_e2e_more">>, <<"_">>}],
    %% The counters probe the caller left running takes one of the two slots.
    {<<"calltrace_started">>, Id, 1, Matched, 600, 200000, 100} =
        ask(Target, {<<"start_calltrace">>, [Pin], Patterns, 600, 200000, 100}),
    check("a call tree probe matches the functions of both modules", Matched >= 3),
    {<<"error">>, <<"probe_limit">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], Patterns, 600, 200000, 100}),
    check("a second call tree probe is refused", true),
    timer:sleep(250),
    {<<"calltrace">>, Id, <<"running">>, <<"running">>, {_, _, Mid, _, _, _, _, _, _, _, _, _, _, _, _}, _, _, _} =
        ask(Target, {<<"read_calltrace">>, Id}),
    check("a running call tree probe can be read and has events", Mid > 0),
    timer:sleep(700),
    {<<"calltrace">>, Id, <<"finished">>, <<"deadline">>,
     {<<"traced_call_return_to">>, Elapsed, Events, 200000, Dropped, InFlight, Peak, Limit, 0,
      _Forced, Distinct, 0, 0, 0, Depth},
     Frames, Paths, {Pids, Slices}} = ask(Target, {<<"read_calltrace">>, Id}),
    io:format("       call tree: ~b events in ~b ms, ~b paths, peak queue ~b, ~b dropped, ~b in flight~n",
              [Events, Elapsed, Distinct, Peak, Dropped, InFlight]),
    check("the call tree probe stopped at its window", Elapsed >= 550 andalso Elapsed =< 1500),
    check("the call tree probe folded events and kept none", Events > 100 andalso Peak =< Limit),
    check("the call tree reports its depth bound", Depth >= 8),
    check("the paths account for every distinct path", Distinct =:= length(Paths)),
    check("the target is named", length(Pids) =:= 1 andalso is_binary(hd(Pids))),
    NameOf = fun(I) -> {M, F, A, {<<"none">>}} = lists:nth(I + 1, Frames), {M, F, A} end,
    PathNames = [{C, Inc, Exc, [NameOf(I) || I <- Is]} || {C, Inc, Exc, Is} <- Paths],
    check("a path names work/1 under loop/0, leaf first",
          lists:any(fun({C, _, _, [{<<"pg_e2e_work">>, <<"work">>, 1},
                                   {<<"pg_e2e_work">>, <<"loop">>, 0}]}) -> C > 0;
                       (_) -> false end, PathNames)),
    check("a path names more/1 under loop/0, leaf first",
          lists:any(fun({_, _, _, [{<<"pg_e2e_more">>, <<"more">>, 1},
                                   {<<"pg_e2e_work">>, <<"loop">>, 0}]}) -> true;
                       (_) -> false end, PathNames)),
    check("self tail calls do not deepen a path: none is longer than loop/work",
          lists:all(fun({_, _, _, Is}) -> length(Is) =< 2 end, Paths)),
    check("inclusive time is at least exclusive time on every path",
          lists:all(fun({_, Inc, Exc, _}) -> Inc >= Exc andalso Exc >= 0 end, Paths)),
    check("the exclusive times fit inside the window",
          lists:sum([Exc || {_, _, Exc, _} <- Paths]) =< (Elapsed + 50) * 1000000),
    check("every frame index is in the table",
          lists:all(fun({_, _, _, Is}) -> lists:all(fun(I) -> I >= 0 andalso I < length(Frames) end, Is) end,
                    Paths)),
    check("the timeline is bounded and its slices are inside the window",
          length(Slices) =< 100 andalso length(Slices) > 0
          andalso lists:all(fun({0, F, Start, Dur, D}) ->
                                F < length(Frames) andalso Start >= 0 andalso Dur >= 0 andalso D >= 0;
                               (_) -> false end, Slices)),
    {<<"calltrace">>, Id, <<"finished">>, <<"deadline">>, _, _, _, _} =
        ask(Target, {<<"stop_calltrace">>, Id}),
    {<<"error">>, <<"no_such_probe">>, _} = ask(Target, {<<"read_calltrace">>, Id}),
    check("a stopped call tree probe is gone", true),
    {<<"error">>, <<"no_such_probe">>, _} = ask(Target, {<<"read_events">>, Id}),
    check("a read of the wrong kind is no such probe", true),
    %% The event budget is exact, and the tracer cuts the stream itself.
    {<<"calltrace_started">>, Id2, 1, _, 5000, 500, 0} =
        ask(Target, {<<"start_calltrace">>, [Pin], Patterns, 5000, 500, 0}),
    wait_until(fun() ->
        case ask(Target, {<<"read_calltrace">>, Id2}) of
            {<<"calltrace">>, _, <<"finished">>, _, _, _, _, _} -> true;
            _ -> false
        end
    end, 3000),
    {<<"calltrace">>, Id2, <<"finished">>, <<"event_budget">>,
     {_, Elapsed2, 500, 500, _, _, _, _, _, _, _, _, _, _, _}, _, _, {_, []}} =
        ask(Target, {<<"read_calltrace">>, Id2}),
    check("the call tree probe stops at its event budget, well before its window",
          Elapsed2 < 3000),
    {<<"calltrace">>, Id2, _, _, _, _, _, _} = ask(Target, {<<"stop_calltrace">>, Id2}),
    {<<"error">>, <<"unknown_function">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"pg_e2e_work">>, <<"zz_no_such_function">>}],
                     500, 500, 0}),
    {<<"error">>, <<"no_match">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"pg_e2e_work">>, <<"loop">>}, {<<"pg_e2e_more">>, <<"loop">>}],
                     500, 500, 0}),
    {<<"error">>, <<"pattern_too_broad">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"lists">>, <<"_">>}], 500, 500, 0}),
    {<<"error">>, <<"stale_pin">>, _} =
        ask(Target, {<<"start_calltrace">>, [{<<"boot-1">>, 99999}], Patterns, 500, 500, 0}),
    {<<"error">>, <<"bad_request">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin, Pin, Pin, Pin, Pin], Patterns, 500, 500, 0}),
    %% A trailing * is a prefix over the loaded modules: it arms the modules
    %% that match, refuses a bare * and a prefix nothing matches, and never
    %% makes an atom of the text it was given.
    {<<"calltrace_started">>, IdP, 1, MatchedP, _, _, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"pg_e2e_w*">>, <<"_">>}], 500, 500, 0}),
    check("a module prefix arms the one module it matches", MatchedP >= 1 andalso MatchedP < Matched),
    {<<"calltrace">>, IdP, _, _, _, _, _, _} = ask(Target, {<<"stop_calltrace">>, IdP}),
    {<<"error">>, <<"pattern_too_broad">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"*">>, <<"_">>}], 500, 500, 0}),
    check("a bare * is refused as too broad", true),
    {<<"error">>, <<"unknown_module">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"zz_pg_no_such_prefix_*">>, <<"_">>}], 500, 500, 0}),
    check("a prefix that no loaded module starts with is refused", true),
    check("a refused prefix made no atom", not atom_exists(Target, <<"zz_pg_no_such_prefix_">>)),
    {<<"error">>, <<"pattern_too_broad">>, _} =
        ask(Target, {<<"start_calltrace">>, [Pin], [{<<"lis*">>, <<"_">>}], 500, 500, 0}),
    check("a prefix that reaches a hot module is refused by the deny list", true),
    AgentText = pid_text(Target, erpc:call(Target, erlang, whereis, [pickglass_agent])),
    {<<"pinned">>, <<"boot-1">>, AgentPin, AgentText} = ask(Target, {<<"pin">>, AgentText}),
    {<<"error">>, <<"agent_process">>, _} =
        ask(Target, {<<"start_calltrace">>, [{<<"boot-1">>, AgentPin}], Patterns, 500, 500, 0}),
    {<<"error">>, <<"agent_process">>, _} =
        ask(Target, {<<"start_events">>, [{<<"boot-1">>, AgentPin}], 500, 500, 0, 0, 0}),
    check("a probe over the agent's own process is refused", true),
    check("a probe over an unknown, unmatched, too broad or stale target is refused", true),
    check("a refused call tree probe leaves no session behind", length(sessions(Target)) =< 2),
    ok.

%% The scheduling and collection probe.
scenario_events(Target, PinId) ->
    heading("scheduling and collection probe"),
    Pin = {<<"boot-1">>, PinId},
    Supported = erpc:call(Target, erlang, function_exported, [trace, system, 3]),
    {<<"events_started">>, Id, 1, 600, 200000, 50, LongGc, LongSched} =
        ask(Target, {<<"start_events">>, [Pin], 600, 200000, 50, 2, 2}),
    check("an events probe echoes its thresholds where the VM has them",
          case Supported of true -> {LongGc, LongSched} =:= {2, 2}; false -> true end),
    GcBurn = erpc:call(Target, erlang, spawn, [pg_e2e_gc, burn, []]),
    timer:sleep(300),
    {<<"events">>, Id, <<"running">>, <<"running">>, {_, _, MidEvents, _, _, _, _, _, _, _, _, _, _, _, _}, _, _, _} =
        ask(Target, {<<"read_events">>, Id}),
    check("a running events probe can be read and has events", MidEvents > 0),
    timer:sleep(700),
    {<<"events">>, Id, <<"finished">>, <<"deadline">>,
     {<<"traced_running_gc">>, Elapsed, Events, 200000, _Dropped, _InFlight, _Peak, _Limit, 0,
      _Unpaired, _SlicesDropped, LongSeen, _Strays, 2, 2},
     Procs, Slices, Long} = ask(Target, {<<"read_events">>, Id}),
    io:format("       events: ~b events in ~b ms, ~b slices, ~b long events~n",
              [Events, Elapsed, length(Slices), LongSeen]),
    check("the events probe stopped at its window", Elapsed >= 550 andalso Elapsed =< 1500),
    [{ProcText, Runs, RunNs, Minor, Major, GcNs}] = Procs,
    check("the target ran, and the run time is time on a scheduler",
          is_binary(ProcText) andalso Runs > 10 andalso RunNs > 0
          andalso RunNs =< (Elapsed + 50) * 1000000),
    check("the target collected garbage", Minor + Major > 0 andalso GcNs >= 0),
    check("the slices are bounded and name runs and collections",
          length(Slices) =< 50 andalso length(Slices) > 0
          andalso lists:all(fun({0, K, Start, Dur}) ->
                                lists:member(K, [<<"run">>, <<"gc_minor">>, <<"gc_major">>])
                                andalso Start >= 0 andalso Dur >= 0;
                               (_) -> false end, Slices)),
    case Supported of
        true ->
            check("a node-wide slow collection of an unpinned process is reported",
                  lists:any(fun({<<"long_gc">>, P, Ms, Words}) ->
                                    is_binary(P) andalso Ms >= 2 andalso Words >= 0;
                               (_) -> false end, Long)),
            ok;
        false ->
            check("an old VM refuses thresholds", true)
    end,
    _ = GcBurn,
    {<<"events">>, Id, <<"finished">>, <<"deadline">>, _, _, _, _} =
        ask(Target, {<<"stop_events">>, Id}),
    {<<"error">>, <<"no_such_probe">>, _} = ask(Target, {<<"read_events">>, Id}),
    check("a stopped events probe is gone", true),
    %% The budget, exact.
    {<<"events_started">>, Id2, 1, 5000, 100, 0, 0, 0} =
        ask(Target, {<<"start_events">>, [Pin], 5000, 100, 0, 0, 0}),
    wait_until(fun() ->
        case ask(Target, {<<"read_events">>, Id2}) of
            {<<"events">>, _, <<"finished">>, _, _, _, _, _} -> true;
            _ -> false
        end
    end, 3000),
    {<<"events">>, Id2, <<"finished">>, <<"event_budget">>, {_, Elapsed2, 100, 100, _, _, _, _, _, _, _, _, _, 0, 0},
     _, _, []} = ask(Target, {<<"read_events">>, Id2}),
    check("the events probe stops at its event budget", Elapsed2 < 3000),
    {<<"events">>, Id2, _, _, _, _, _, _} = ask(Target, {<<"stop_events">>, Id2}),
    check("a refused events probe leaves no session behind", length(sessions(Target)) =< 2),
    ok.

%% Floods: processes that emit events faster than the tracer can fold them.
%% The tracer must watch its own mailbox and stop the probe with `overrun`
%% instead of letting it grow, and the target must keep running.
scenario_trace_floods(Target) ->
    heading("flooded tracers"),
    Spinners = erpc:call(Target, pg_e2e_flood, start, [spin, 4]),
    Yielders = erpc:call(Target, pg_e2e_flood, start, [yielder, 4]),
    Pin = fun(P) ->
              {<<"pinned">>, <<"boot-1">>, I, _} = ask(Target, {<<"pin">>, pid_text(Target, P)}),
              {<<"boot-1">>, I}
          end,
    SpinPins = [Pin(P) || P <- Spinners],
    YieldPins = [Pin(P) || P <- Yielders],
    {<<"calltrace_started">>, Id, 4, _, 5000, 200000, 0} =
        ask(Target, {<<"start_calltrace">>, SpinPins, [{<<"pg_e2e_flood">>, <<"_">>}], 5000, 200000, 0}),
    wait_until(fun() ->
        case ask(Target, {<<"read_calltrace">>, Id}) of
            {<<"calltrace">>, _, <<"finished">>, _, _, _, _, _} -> true;
            _ -> false
        end
    end, 6000),
    {<<"calltrace">>, Id, <<"finished">>, CStop,
     {_, CElapsed, CEvents, _, CDropped, CInFlight, CPeak, CLimit, 0, _, _, _, _, _, _},
     _, _, _} = ask(Target, {<<"read_calltrace">>, Id}),
    io:format("       flooded call tree: stop ~s after ~b ms, ~b events, ~b in flight, ~b dropped, peak queue ~b~n",
              [CStop, CElapsed, CEvents, CInFlight, CDropped, CPeak]),
    %% Whether the tracer or the targets win depends on how many schedulers the
    %% machine has: with few, the high priority tracer keeps up and the probe
    %% spends its budget. Either way the bound held. The suspended tracer below
    %% makes overrun certain.
    check("a flooded call tree probe stops at its mailbox limit or its budget",
          CStop =:= <<"overrun">> orelse CStop =:= <<"event_budget">>),
    check("the flooded call tree probe stopped long before its window", CElapsed < 4000),
    check("the flooded tracer's mailbox stayed within a few times its limit",
          CPeak =< 4 * CLimit andalso CInFlight =< 4 * CLimit),
    check("the call tree probe reports what it left unread", CDropped >= 0 andalso CEvents > 0),
    {<<"calltrace">>, Id, _, _, _, _, _, _} = ask(Target, {<<"stop_calltrace">>, Id}),
    %% A tracer that cannot keep up: suspended for a moment while the targets
    %% flood it, it must find its mailbox past the limit when it resumes.
    {<<"calltrace_started">>, Id3, 4, _, _, _, _} =
        ask(Target, {<<"start_calltrace">>, SpinPins, [{<<"pg_e2e_flood">>, <<"_">>}], 5000, 200000, 0}),
    Tracers = tracers(Target),
    check("the call tree probe has a tracer process", length(Tracers) =:= 1),
    [erpc:call(Target, sys, suspend, [T]) || T <- Tracers],
    timer:sleep(30),
    [erpc:call(Target, sys, resume, [T]) || T <- Tracers],
    wait_until(fun() ->
        case ask(Target, {<<"read_calltrace">>, Id3}) of
            {<<"calltrace">>, _, <<"finished">>, _, _, _, _, _} -> true;
            _ -> false
        end
    end, 6000),
    {<<"calltrace">>, Id3, <<"finished">>, <<"overrun">>,
     {_, SElapsed, SEvents, _, SDropped, SInFlight, _, SLimit, 0, _, _, _, _, _, _},
     _, _, _} = ask(Target, {<<"read_calltrace">>, Id3}),
    io:format("       suspended call tree: ~b ms, ~b events folded, ~b in flight at stop, ~b dropped~n",
              [SElapsed, SEvents, SInFlight, SDropped]),
    check("a tracer that falls behind stops with overrun and reports its backlog",
          SInFlight > SLimit andalso SDropped >= SInFlight andalso SEvents =< 200000),
    {<<"calltrace">>, Id3, _, _, _, _, _, _} = ask(Target, {<<"stop_calltrace">>, Id3}),
    {<<"events_started">>, Id2, 4, _, _, _, _, _} =
        ask(Target, {<<"start_events">>, YieldPins, 5000, 200000, 0, 0, 0}),
    wait_until(fun() ->
        case ask(Target, {<<"read_events">>, Id2}) of
            {<<"events">>, _, <<"finished">>, _, _, _, _, _} -> true;
            _ -> false
        end
    end, 6000),
    {<<"events">>, Id2, <<"finished">>, EStop,
     {_, EElapsed, EEvents, _, EDropped, EInFlight, EPeak, ELimit, 0, _, _, _, _, _, _},
     _, _, _} = ask(Target, {<<"read_events">>, Id2}),
    io:format("       flooded events: stop ~s after ~b ms, ~b events, ~b in flight, ~b dropped, peak queue ~b~n",
              [EStop, EElapsed, EEvents, EInFlight, EDropped, EPeak]),
    check("a flooded events probe reports overrun or spends its budget",
          EStop =:= <<"overrun">> orelse EStop =:= <<"event_budget">>),
    check("the flooded events tracer's mailbox stayed within a few times its limit",
          EPeak =< 4 * ELimit andalso EInFlight =< 4 * ELimit),
    {<<"events">>, Id2, _, _, _, _, _, _} = ask(Target, {<<"stop_events">>, Id2}),
    check("the flooded targets are still running",
          lists:all(fun(P) -> erpc:call(Target, erlang, is_process_alive, [P]) end, Spinners ++ Yielders)),
    [exit(P, kill) || P <- Spinners ++ Yielders],
    check("no trace session is left after the floods", length(sessions(Target)) =< 2),
    ok.

%% A probe that did not ask for allocation answers `none` and not zeros.
ask_time_only_memory(Target, Pins) ->
    {<<"counters_started">>, Id, _, _} =
        ask(Target, {<<"start_counter_set">>, [{<<"pg_e2e_work">>, <<"work">>}], Pins, 5000,
                     <<"time">>}),
    Reply = ask(Target, {<<"read_counter_memory">>, Id}),
    {<<"counters">>, Id, _, _, _, _, _} = ask(Target, {<<"stop_counters">>, Id}),
    Reply.

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

%% The ETS listing, the owners census with per-owner ETS memory and initial
%% calls, and tables that vanish while the walk runs.
scenario_ets(Target) ->
    Cache = {pickglass_owner, 1, [{<<"app">>, <<"e2e_ets">>}], <<"cache">>},
    Mine = erpc:call(Target, pg_e2e_ets, table, [pg_e2e_ets_labelled, 3000, Cache]),
    Plain = erpc:call(Target, pg_e2e_ets, table, [pg_e2e_ets_plain, 500, none]),
    timer:sleep(200),
    {<<"ets_tables">>, {Total, Counted, Skipped, <<"finished">>, _}, Tables, {NTables, NObjects, NBytes}} =
        ask(Target, {<<"ets_tables">>, 500}),
    check("the listing covers every table", Counted + Skipped =< Total andalso Counted >= 2),
    check("the totals cover every table read", NTables =:= Counted andalso NObjects >= 3500 andalso NBytes > 0),
    Find = fun(Name) ->
               [T || {_, N, _, _, _, _, _, _, _} = T <- Tables, N =:= Name]
           end,
    [{LId, <<"pg_e2e_ets_labelled">>, LOwnerPid, LOwner, <<"set">>, 3000, LMem, <<"public">>, <<>>}] =
        Find(<<"pg_e2e_ets_labelled">>),
    check("a named table is listed with its owner, size and memory",
          LOwnerPid =:= pid_text(Target, Mine) andalso LMem > 3000 andalso
          is_binary(LId) andalso byte_size(LId) > 0),
    check("the owner's label is decoded",
          LOwner =:= {<<"owner">>, [{<<"app">>, <<"e2e_ets">>}], <<"cache">>}),
    [{_, _, PPid, POwner, _, 500, _, _, _}] = Find(<<"pg_e2e_ets_plain">>),
    check("an unlabelled owner is unknown", PPid =:= pid_text(Target, Plain) andalso POwner =:= {<<"unknown">>}),
    Mems = [M || {_, _, _, _, _, _, M, _, _} <- Tables],
    check("tables are listed largest first", Mems =:= lists:reverse(lists:sort(Mems))),
    {<<"ets_tables">>, _, Two, _} = ask(Target, {<<"ets_tables">>, 2}),
    check("the listing is bounded by the requested count", length(Two) =:= 2),
    {<<"ets_tables">>, _, Default, _} = ask(Target, {<<"ets_tables">>}),
    check("the listing defaults to at most 100 tables", length(Default) =< 100),
    io:format("       ets listing: ~b tables, ~b objects, ~b bytes; top: ~p~n",
              [NTables, NObjects, NBytes,
               [{N, M} || {_, N, _, _, _, _, M, _, _} <- lists:sublist(Tables, 3)]]),
    {<<"owners_detail">>, _, DRows, DAggs, DTotals, {EtsTables, EtsBytes, _, <<"finished">>}} =
        ask(Target, {<<"owners_detail">>, 100000, 200}),
    check("owners_detail rows carry a twelfth field, the initial call",
          DRows =/= [] andalso lists:all(fun(R) -> tuple_size(R) =:= 12 end, DRows)),
    check("a supervisor's initial call identifies it as one",
          lists:any(fun(R) -> case element(12, R) of
                                  <<"supervisor:", _/binary>> -> true;
                                  _ -> false
                              end end, DRows)),
    check("owners_detail aggregates carry ETS tables and bytes",
          lists:all(fun(A) -> tuple_size(A) =:= 8 end, DAggs)),
    check("an owner's ETS memory is attributed to its label",
          lists:any(fun({{<<"owner">>, [{<<"app">>, <<"e2e_ets">>}], <<"cache">>}, _, _, _, _, _, T, B}) ->
                            T =:= 1 andalso B > 3000;
                       (_) -> false end, DAggs)),
    check("tables of an unlabelled process count under unknown",
          lists:any(fun({{<<"unknown">>}, _, _, _, _, _, T, B}) -> T >= 1 andalso B > 500;
                       (_) -> false end, DAggs)),
    check("the ETS pass covers at least the listed owners' tables",
          EtsTables >= 2 andalso EtsBytes >= 3500 andalso tuple_size(DTotals) =:= 7),
    {<<"owners">>, _, _, OldAggs, _} = ask(Target, {<<"owners">>, 100000, 10}),
    check("the older owners reply keeps its six-field shape",
          lists:all(fun(A) -> tuple_size(A) =:= 6 end, OldAggs)),
    %% Tables created and deleted by another process while the walk runs: each
    %% walk accounts for every table it listed, as counted or as skipped.
    Churn = erpc:call(Target, pg_e2e_ets, churn, []),
    Walks = [ask(Target, {<<"ets_tables">>, 5}) || _ <- lists:seq(1, 40)],
    SkippedSeen = lists:sum([Sk || {<<"ets_tables">>, {_, _, Sk, _, _}, _, _} <- Walks]),
    check("a table deleted mid-walk is counted and never a crash",
          lists:all(fun({<<"ets_tables">>, {T, C, Sk, <<"finished">>, _}, _, _}) ->
                            C + Sk =< T andalso C >= 1;
                       (_) -> false end, Walks)),
    io:format("       ~b tables were deleted mid-walk across 40 listings~n", [SkippedSeen]),
    [exit(P, kill) || P <- [Mine, Plain, Churn]],
    ok.

%% Binary references of a pinned process: summed and listed within a budget,
%% and refused, never summarised, for a process that holds more than the agent
%% reads.
scenario_binaries(Target) ->
    Pin = fun(P) ->
              {<<"pinned">>, <<"boot-1">>, Id, _} = ask(Target, {<<"pin">>, pid_text(Target, P)}),
              {<<"boot-1">>, Id}
          end,
    Small = erpc:call(Target, pg_e2e_ets, hold, [100, 1000]),
    Few = erpc:call(Target, pg_e2e_ets, hold, [3, 200000]),
    timer:sleep(200),
    {<<"binaries">>, SmallText, Count, Bytes, Refs, Rows} =
        ask(Target, {<<"binaries">>, Pin(Small), 5}),
    check("the binaries of a pinned process are summed",
          SmallText =:= pid_text(Target, Small) andalso Count >= 100 andalso
          Bytes >= 100000 andalso Refs >= Count),
    check("the listing is bounded and largest first",
          length(Rows) =:= 5 andalso
          lists:all(fun({A, B, R}) -> is_binary(A) andalso B >= 1000 andalso R >= 1 end, Rows)),
    {<<"binaries">>, _, 3, FewBytes, _, [{_, 200000, _} | _] = FewRows} =
        ask(Target, {<<"binaries">>, Pin(Few), 200}),
    check("large binaries are listed with their sizes",
          FewBytes >= 600000 andalso length(FewRows) =:= 3),
    {<<"error">>, <<"stale_pin">>, _} = ask(Target, {<<"binaries">>, {<<"boot-1">>, 99999}, 5}),
    check("binaries refuses a pin that does not exist", true),
    %% More than the budget: counted and refused.
    Many = erpc:call(Target, pg_e2e_ets, hold, [60000, 70]),
    timer:sleep(1500),
    {<<"error">>, <<"too_many_binaries">>, _} = ask(Target, {<<"binaries">>, Pin(Many), 5}),
    check("a process past the list budget is refused as too_many_binaries", true),
    %% So many that receiving the list passes the worker's heap cap.
    Huge = erpc:call(Target, pg_e2e_ets, hold, [400000, 70]),
    timer:sleep(4000),
    {<<"error">>, <<"too_many_binaries">>, _} = ask(Target, {<<"binaries">>, Pin(Huge), 5}),
    check("a process whose list overruns the worker's heap is refused the same way", true),
    {<<"pong">>, _, _, _, _, _, _} = ask(Target, {<<"ping">>}),
    check("the agent answers after both refusals", true),
    [exit(P, kill) || P <- [Small, Few, Many, Huge]],
    ok.

%% An explicit detach replies after the session is destroyed.
scenario_detach(Target, Work) ->
    heading("explicit detach"),
    Link = spawn(fun() -> receive stop -> ok end end),
    Agent = start_agent(Target, Link),
    {<<"counters_started">>, _, _, _} =
        ask(Target, {<<"start_counters">>, <<"pg_e2e_work">>, <<"work">>, {<<"all">>}, 60000}),
    check("a probe over all processes is running", length(sessions(Target)) >= 2),
    {<<"pinned">>, <<"boot-1">>, DPin, _} = ask(Target, {<<"pin">>, pid_text(Target, Work)}),
    {<<"calltrace_started">>, _, 1, _, _, _, _} =
        ask(Target, {<<"start_calltrace">>, [{<<"boot-1">>, DPin}],
                     [{<<"pg_e2e_work">>, <<"_">>}], 10000, 200000, 0}),
    check("a call tree probe and a counters probe are both running",
          length(sessions(Target)) >= 3),
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
    {<<"pinned">>, <<"boot-2">>, SPin, _} = ask(Target, {<<"pin">>, pid_text(Target, Work)}),
    {<<"stacks_started">>, _, _, _, _, _} =
        ask(Target, {<<"start_stacks">>, [{<<"boot-2">>, SPin}], 100, 60000, 1000000}),
    timer:sleep(200),
    check("a sampler process is running mid sample", length(agent_processes(Target)) >= 2),
    Before = erpc:call(Target, erlang, system_info, [process_count]),
    OsPid = erpc:call(V, os, getpid, []),
    _ = os:cmd("kill -9 " ++ OsPid),
    torn_down(Target, Agent, Work, "after kill -9 of the viewer"),
    After = erpc:call(Target, erlang, system_info, [process_count]),
    check("the target kept its processes (" ++ integer_to_list(Before) ++ " -> "
          ++ integer_to_list(After) ++ ")", abs(After - Before) =< 10).

%% The viewer's OS process is killed while both event probes are tracing. The
%% sessions, the tracers and the agent must all be gone, and the traced
%% process must keep running.
scenario_viewer_killed_tracing(Target, Work) ->
    heading("viewer killed with SIGKILL while tracing"),
    {ok, _VPeer, V} = peer:start(#{name => node_name("pg_e2e_viewer"),
                                  args => ["-hidden", "-setcookie", "pg_e2e_cookie"]}),
    VLink = erpc:call(V, erlang, spawn, [timer, sleep, [infinity]]),
    {ok, Agent} = erpc:call(V, erpc, call,
                            [Target, pickglass_agent@server, start,
                             [{VLink, <<"boot-3">>, 30000}]]),
    {<<"pinned">>, <<"boot-3">>, Pin, _} = ask(Target, {<<"pin">>, pid_text(Target, Work)}),
    {<<"calltrace_started">>, _, 1, _, _, _, _} =
        ask(Target, {<<"start_calltrace">>, [{<<"boot-3">>, Pin}],
                     [{<<"pg_e2e_work">>, <<"_">>}], 10000, 200000, 0}),
    {<<"events_started">>, _, 1, _, _, _, _, _} =
        ask(Target, {<<"start_events">>, [{<<"boot-3">>, Pin}], 60000, 200000, 0, 0, 0}),
    timer:sleep(200),
    check("both event probes have a session and a tracer", length(sessions(Target)) >= 3
          andalso length(agent_processes(Target)) >= 3),
    check("the traced process carries a session's trace flags",
          lists:any(fun(S) -> {flags, F} = erpc:call(Target, trace, info, [S, Work, flags]), F =/= [] end,
                    [S || S <- sessions(Target), S =/= {legacy, default}])),
    OsPid = erpc:call(V, os, getpid, []),
    _ = os:cmd("kill -9 " ++ OsPid),
    torn_down(Target, Agent, Work, "after kill -9 of the viewer mid trace"),
    ok.

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
    check("no process carries the agent's label " ++ When,
          wait_until(fun() -> agent_processes(Target) =:= [] end, 5000)),
    check("the registered name is free " ++ When,
          erpc:call(Target, erlang, whereis, [pickglass_agent]) =:= undefined),
    check("the target's own process survived " ++ When,
          erpc:call(Target, erlang, is_process_alive, [Work])),
    ok = push(Target, beams(ebin_dir())).

sessions(Target) ->
    erpc:call(Target, trace, session_info, [all]).

statistics_on(Target) ->
    erpc:call(Target, erlang, statistics, [scheduler_wall_time]).

%% Processes on the target that carry the agent's ownership label: the agent,
%% its workers, its helpers and its samplers.
agent_processes(Target) ->
    Label = {pickglass_owner, 1, [{<<"tool">>, <<"pickglass">>}], <<"agent">>},
    [P || P <- erpc:call(Target, erlang, processes, []),
          erpc:call(Target, erlang, process_info, [P, label]) =:= {label, Label}].

%% The tracer processes of the agent's event probes, found by their initial
%% call, which is how the agent starts them.
tracers(Target) ->
    [P || P <- agent_processes(Target),
          case erpc:call(Target, proc_lib, initial_call, [P]) of
              {pickglass_agent@tracer, init, _} -> true;
              _ -> false
          end].

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
    _ = load_source(Target, "pg_e2e_gc",
        "-module(pg_e2e_gc). -export([burn/0]). "
        "burn() -> L = lists:seq(1, 3000000), erlang:garbage_collect(), length(L). "),
    _ = load_source(Target, "pg_e2e_flood",
        "-module(pg_e2e_flood). -export([start/2, spin/0, yielder/0, hot/1]). "
        "start(Kind, N) -> [spawn(pg_e2e_flood, Kind, []) || _ <- lists:seq(1, N)]. "
        "spin() -> hot(1), spin(). "
        "hot(X) -> X + 1. "
        "yielder() -> erlang:yield(), yielder(). "),
    _ = load_source(Target, "pg_e2e_ets",
        "-module(pg_e2e_ets). -export([table/3, hold/2, churn/0]). "
        "table(Name, N, Label) -> spawn(fun() -> "
        "  case Label of none -> ok; _ -> proc_lib:set_label(Label) end, "
        "  T = ets:new(Name, [named_table, public, set]), "
        "  [ets:insert(T, {I, I}) || I <- lists:seq(1, N)], "
        "  receive stop -> ok end end). "
        "hold(N, Size) -> spawn(fun() -> "
        "  L = [binary:copy(<<\"x\">>, Size) || _ <- lists:seq(1, N)], "
        "  receive stop -> length(L) end end). "
        "churn() -> spawn(fun() -> churn_loop() end). "
        "churn_loop() -> "
        "  Ts = [ets:new(pg_e2e_churn, []) || _ <- lists:seq(1, 300)], "
        "  [ets:delete(T) || T <- Ts], churn_loop(). "),
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
