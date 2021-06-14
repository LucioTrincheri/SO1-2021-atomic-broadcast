-module(ledger).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([append/1, get/0]).
-export([listPending/1, clientCounter/1, ledgerLoop/1]).

-define(TIEMPO, 2000).

-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

start() ->
    ?Dbg("Inicializando...~n"),
    isis:start(),
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
    ok.

clientCounter(C) ->
    receive
        {get, PId} ->
            PId ! C + 1,
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

get() ->
    counter ! {get, self()},
    receive
        C ->
            lists:foreach(fun (X) ->
                          {ledger, X} ! {reqGet, C, self()} end,
                          nodes()++[node()]),
            receive
                {getRes, C, V} -> %% TODO si nadie responde dentro de mucho tiempo asumo que estoy muerto, muero.
                    borrarInbox(),
                    V
            end
    end.

append(Msg) ->
    counter ! {get, self()},
    receive
        C ->
            lists:foreach(fun (X) ->
                          {ledger, X} ! {reqAppend, C, Msg, self()} end,
                          nodes()++[node()]),
            receive
                {appendRes, C, Response} -> %% TODO si nadie responde dentro de mucho tiempo asumo que estoy muerto, muero.
                    borrarInbox(),
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

%! Problema ISIS
% ISIS -> Si dos nodos con valor interno 0 mandan un mensaje exactamente al mismo momento, ambos terminan con valor 1 como final de mensaje. Solucionar.
% Se puede solucionar el problema poniendo el PId como parte decimal del valor del mensaje.
% Ejemplos: P1 -> PId = 15, P2 -> PId = 20.
% Ambos mandan su mensaje, ambos asignan 1 como valor.
% Cuando te llega el mensaje, ambos tiene 1 como NA.
% Agregas tu PId como parte decimal. Ahora los mensajes tienen valor
% 1,15 y 1,20. Ambos estan ordenados. Respondo a todos los nodos.
% Para actualizar tu A, haces max(A, floor(NA)). Todo 10 punto.

%? Tema valor f de parada
% Para el valor f de fallo < n/2, n lo podemos sacar de la siguiente manera:
% Sabemos que cuando comienzan los ledger (y por lo tanto is-is), todos
% los nodos que van a formar parte de la red ya tienen nombre.
% Por lo tanto, es posible saber la cantidad iniciar con length(nodes()) / 2.
% Guardar este valor en alguna parte (agente que monitoree los servidores.
% Si se cae alguno resta 1. Este agente devulve si es posible seguir
% operando. Si luego de la resta la cantidad queda por debajo o igual a f,
% devulve false; en caso contrario devuelve true.
