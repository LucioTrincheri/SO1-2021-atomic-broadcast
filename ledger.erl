-module(ledger).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([ledgerAppend/1, ledgerGet/0]).
-export([listPending/1, clientCounter/1, ledgerLoop/1, aliveCounter/1]).

-define(TIEMPO, 2000).

-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

start() ->
    isis:start(),
    register(alive, spawn(?MODULE, aliveCounter, [((length(nodes()) + 1) / 2)])), %Tomo la mitad de nodos iniciales como el f de parada.
    register(appendPend, spawn(?MODULE, listPending, [[]])),
    register(getPend, spawn(?MODULE, listPending, [[]])),
    register(counter, spawn(?MODULE, clientCounter, [0])),
    register(ledger, spawn(?MODULE, ledgerLoop, [[]])),
    ok.

stop()->
    isis:stop(),
    appendPend ! fin,
    getPend ! fin,
    counter ! fin,
    ledger ! fin,
    unregister(appendPend),
    unregister(getPend),
    unregister(counter),
    unregister(ledger),
    unregister(alive),
    ok.


aliveCounter(F) ->
    L = length(nodes()) + 1,
    case ((L < F) or (L =< 1)) of
        true ->
            ?Dbg("La red se quedo vacia como yo sin ella...muriendo :_c~p~n", [F]),
            stop();
        false -> aliveCounter(F)
    end. 

clientCounter(C) ->
    receive
        {get, PId} ->
            PId ! C,
            clientCounter(C);
        incr ->
            clientCounter(C + 1);
        fin -> ok
    end.

listPending(L) ->
    receive
        % N de nodo
        {store, C, PId} ->
            listPending([{C, PId}]++L);
        {remove, C, PId} ->
            listPending(lists:delete({C, PId}, L));
        {find, C, MPId, PId} ->
            PId ! lists:member({C, MPId}, L),
            listPending(L);
        fin -> ok
    end.

borrarInbox() ->
    receive
        _ -> borrarInbox()
    after
        0 -> ok
    end.

ledgerGet() ->
    counter ! {get, self()},
    receive
        {_,_,_} -> 
            ledgerGet();
        C ->
            counter ! incr,
            B = C + 1,
            lists:foreach(fun (X) ->
                          {ledger, X} ! {reqGet, B, self()} end,
                          nodes()++[node()]),
            receive
                {getRes, B, V} -> %% TODO si nadie responde dentro de mucho tiempo asumo que estoy muerto, muero.
                    borrarInbox(),
                    V
            end
    end.

ledgerAppend(Msg) ->
    counter ! {get, self()},
    receive
        % Si un mensaje llego despues de limpiar la inbox pero antes de una nueva llamada a append.
        {_,_,_} -> 
            ledgerAppend(Msg);
        C ->
            counter ! incr,
            B = C + 1,
            lists:foreach(fun (X) ->
                          {ledger, X} ! {reqAppend, B, Msg, self()} end,
                          nodes()++[node()]),
            receive
                {appendRes, B, Response} -> %% TODO si nadie responde dentro de mucho tiempo asumo que estoy muerto, muero.
                    borrarInbox(), % Para seguir la idea de implementacion (aunque no sea necesario), se borran los mensajes que no nos importan
                    Response
            end
    end.

ledgerLoop(Hist) ->
    receive
        {reqGet, C, PId} ->
            isis:broadcast({reqGet, C, PId}),
            getPend ! {store, C, PId},
            ledgerLoop(Hist);
        {reqAppend, C, Msg, PId} ->
            isis:broadcast({reqAppend, C, Msg, PId}),
            appendPend ! {store, C, PId},
            ledgerLoop(Hist);
        fin -> ok
    after 50 ->
        case isis:pop() of
            noMsgs -> 
                ledgerLoop(Hist);
            {reqGet, C, PId} -> 
                getPend ! {find, C, PId, self()},
                receive
                    true ->
                        PId ! {getRes, C, Hist},
                        getPend ! {remove, C, PId};
                    false -> notGetPending
                end,
                ledgerLoop(Hist);
            {reqAppend, C, Msg, PId} ->
                appendPend ! {find, C, PId, self()},
                receive
                    true -> % En este caso, si esta contained, no hay posibildid que ya se haya guardado el mensaje en el historial. Hacemos todo en 1 receive
                        PId ! {appendRes, C, ok},
                        appendPend ! {remove, C, PId},
                        ledgerLoop([Msg] ++ Hist);
                    false -> ledgerLoop(Hist)
                end
        end
    end.
