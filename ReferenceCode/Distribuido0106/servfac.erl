-module(servfac).
-export([init/0,stop/0]).
-export([loopFac/0]).

init() ->
    register(facserv, spawn(?MODULE, loopFac,[])).

stop() ->
    facserv ! fin,
    unregister(facserv).

%% Loop Servicio
loopFac() ->
    receive
        {Pid, N} ->
            Pid ! {ok, fac(N)},
            loopFac();
        fin -> ok;
        _ -> loopFac()
    end.

fac(0) ->
    1;
fac(N) when N > 0 ->
    N * fac(N-1);
fac(_) ->
    err.
