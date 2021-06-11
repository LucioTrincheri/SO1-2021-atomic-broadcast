-module(isis).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([broadcast/1, get/0]).
-export([isisLoop/3, pqueue/1, processNA/1]).
-export([tracker/4]).
-define(TIEMPO, 2000).
-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

start() ->
    register(loop, spawn(?MODULE, isisLoop, [0,0,0])),
    register(queue, spawn(?MODULE, pqueue, [[]])),
    register(receiver, spawn(?MODULE, processNA, [maps:new()])),
    ok.

stop()->
    loop ! fin,
    queue ! fin,
    receiver ! fin,
    unregister(loop),
    unregister(queue),
    unregister(receiver),
    ok.

get() ->
    queue ! {get, self()},
    ?Dbg("[Get]: Esperando mensaje...~n"),
    receive
        noMsgs -> io:format("No hay mensajes nuevos~n");
        
        {Msg, _, _, _} -> Msg
    end.

broadcast(Msg) ->
    loop ! {getNP, Msg},
    ?Dbg("[Broadcast]: Peticion de broadcast enviada a isisLoop~n"),
    ok.


tracker(Msg, I, P, []) ->
    ?Dbg("[Traker]: Recibí respuesta de todos. Nro de orden final: ~p~n", [P]),
    receiver ! {endNA, Msg, I, P};
tracker (Msg, I, P, Nodes) ->
    receive
        {updateNA, NP, Node} -> 
            ?Dbg("[Traker]: Recibí respuesta de ~p. Nro de orden: ~p~n", [Node, NP]),
            tracker(Msg, I, erlang:max(P, NP), lists:delete(Node, Nodes))
    after 
        ?TIEMPO ->
            ?Dbg("[Traker]: Tiempo de espera agotado, retorno ~p~n", [P]),
            receiver ! {endNA, Msg, I, P}
    end.

% Lista de mensajes que deben esperar respuestas nodos (numeros provisorio) 
% tal vez la lista tenga asociado al mensaje un pid del agente encargado del conteo.
% L mapa de K:I {AgentePid}
processNA(L) ->
    receive
        {generateMsg, Msg, I, P, Nodes} ->
            ?Dbg("[processNA]: Nuevo mensaje a ordenar ~p, nodos a esperar ~p~n", [Msg, Nodes]),
            APid = spawn(?MODULE, tracker, [Msg, I, P, Nodes]),
            processNA(maps:put(I, APid, L));
        
        {calculateNA, I, NP, Node} -> 
            ?Dbg("[processNA]: Me respondieron la propuesta de numero, envio a tracker. NP: ~p, Nodo: ~p~n", [NP, Node]),
            maps:get(I, L) ! {updateNA, NP, Node},
            processNA(L);
        
        {endNA, Msg, I, NA} -> 
            ?Dbg("[processNA]: El tracker del mensaje: ~p, terminó~n", [Msg]),
            loop ! {recNA, Msg, I, NA},
            processNA(maps:remove(I, L));
        
        fin -> ok
    end.

pqueue(L) ->
    receive
        % Guarda un mensaje con un valor provisorio.
        {store, Msg, I, P} -> 
            ?Dbg("[pqueue]: Guardar mensaje ~p, con identificador: ~p~n", [Msg, I]),
            pqueue([{Msg, I, P, prov}] ++ L);

        % Actualiza el mensaje con un valor acordado. 
        {update, Msg, I, NA} -> 
            ?Dbg("[pqueue]: Actualizar estado de mensaje ~p, valor NA: ~p~n", [Msg, NA]),
            pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, acord}));

        % Si es posible, realiza un pop en la queue.
        {get, Pid} ->
            case L of
                [] -> 
                    Pid ! noMsgs,
                    pqueue([]);
                _ ->
                    First = lists:nth(1, lists:keysort(3, L)),
                    case First of
                        {_,_,_,acord} ->
                            ?Dbg("[pqueue]: Primer mensaje con estado acrod, lo devuelvo. Msg: ~p~n", [First]),
                            Pid ! First,
                            pqueue(lists:delete(First, L));
                        {_,_,_,prov} -> %TODO tal vez hacer un wait
                            ?Dbg("[pqueue]: Primer mensaje con estado prov reitero~n"),
                            self() ! {get, Pid},
                            pqueue(L)
                    end
            end;
        fin -> ok
    end.

isisLoop (A, P, N) ->
    receive
        % Dado el identificador del nuevo mensaje y los 
        % nodos de los cuales esperar respuesta, guarda
        % el mensaje en la queue y crea un nuevo agente
        % que espera el numero provisorio de cada nodo  
        {getNP, Msg} -> 
            IOList = io_lib:format("~w", [node()]),
            FlattenList = lists:flatten(IOList),
            I = FlattenList ++ integer_to_list(N),
            ?Dbg("[isisLoop]: Nuevo mensaje a enviar I: ~p~n", [I]),
            queue ! {store, Msg, I, P},
            receiver ! {generateMsg, Msg, I, P, nodes()},
            lists:foreach(fun (X) ->
                          {loop, X} ! {reqNP, Msg, I, node()} end,
                          nodes()),
            isisLoop(A, P, N + 1);
        
        % Dado un nuevo mensaje, lo guarda en la queue
        % y responde al emisor el numero provisorio
        {reqNP, Msg, I, Node} -> 
            ?Dbg("[isisLoop | reqNP]: Pedido de nuevo valor P: ~p de nodo: ~p~n", [P, Node]),
            NP = erlang:max(A, P) + 1,
            queue ! {store, Msg, I, NP},
            {receiver, Node} ! {calculateNA, I, NP, node()},
            isisLoop(A, NP, N);

        % Dado el numero definitivo calculado por el 
        % agente actualiza el valor de la queue y del
        % nodo y manda este nuevo valor a los nodos.
        {recNA, Msg, I, NA} ->
            ?Dbg("[isisLoop | recNA]: Recibi valor final para mensaje: ~p, con valor ~p~n", [Msg, NA]),
            queue ! {update, Msg, I, NA},
            lists:foreach(fun (X) ->
                          {loop, X} ! {updNA, Msg, I, NA} end,
                          nodes()),
            isisLoop(erlang:max(A, NA), P, N);

        % Actualiza el valor acordado en la queue y en el nodo 
        {updNA, Msg, I, NA} ->
            ?Dbg("[isisLoop | updNA]: Recibi update valor final para mensaje: ~p, con valor ~p~n", [Msg, NA]),
            queue ! {update, Msg, I, NA},
            isisLoop(erlang:max(A, NA), P, N);
        
        fin -> ok
    end.
