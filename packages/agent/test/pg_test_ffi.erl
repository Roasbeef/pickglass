%%% Test-only helpers for the agent's unit tests. Gleam has no `receive`, and
%%% the agent's helpers answer by message, so the tests wait for a reply with
%%% this one function. It lives under `test/`, so it is never part of the
%%% modules pushed into a node.
-module(pg_test_ffi).
-export([await/2]).

%% Wait up to `Timeout` milliseconds for `{<<"pg">>, 1, Ref, Body}` and return
%% `Body`, or the binary `<<"timeout">>`.
await(Ref, Timeout) ->
    receive
        {<<"pg">>, 1, Ref, Body} -> Body
    after Timeout -> <<"timeout">>
    end.
