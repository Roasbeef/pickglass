%%% Test-only helpers for the agent's unit tests. Gleam has no `receive`, and
%%% the agent's helpers answer by message, so the tests wait for a reply, or
%%% for a notice, with these functions. They live under `test/`, so they are
%%% never part of the modules pushed into a node.
-module(pg_test_ffi).
-export([await/2, await_notice/3]).

%% Wait up to `Timeout` milliseconds for `{<<"pg">>, 1, Ref, Body}` and return
%% `Body`, or the binary `<<"timeout">>`.
await(Ref, Timeout) ->
    receive
        {<<"pg">>, 1, Ref, Body} -> Body
    after Timeout -> <<"timeout">>
    end.

%% Wait up to `Timeout` milliseconds for `{Tag, Id}`, the notice a tracer
%% sends the agent when its probe stops, and return `found` or `timeout`.
%% Notices of other probes stay in the mailbox.
await_notice(Tag, Id, Timeout) ->
    receive
        {Tag, Id} -> found
    after Timeout -> timeout
    end.
