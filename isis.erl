-module(isis).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([broadcast/1, pop/0]).
-export([isisLoop/3, pqueue/1, processNA/1]).
-export([tracker/4, ordFun/2]).

-export([p/1]).

-define(TIEMPO, 100).
-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

%! Puede ser necesario que una
%! vez acordado el valor, esperar a que tu valor interno 
%! corresponda con el de tu mensaje enviar (llegaron los anteriores)

p(X) -> net_adm:ping(list_to_atom(X)).

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

pop() ->
    queue ! {pop, self()},
    %%?Dbg("[Pop]: Esperando mensaje...~n"),
    receive
        noMsgs -> 
            %io:format("No hay mensajes nuevos~n"),
            noMsgs;
        {Msg, _, _, _, _} -> Msg
    end.

broadcast(Msg) ->
    loop ! {getNP, Msg},
    ok.

tracker(Msg, I, P, []) ->
    receiver ! {endNA, Msg, I, P};
tracker(Msg, I, P, Nodes) ->
    receive
        {updateNA, NP, Node} -> 
            tracker(Msg, I, erlang:max(P, NP), lists:delete(Node, Nodes));
        fin -> ok
    after 
        ?TIEMPO ->
            tracker(Msg, I, P, lists:filter(fun(Nodo) -> lists:member(Nodo, nodes()) end, Nodes))
    end.

% Lista de mensajes que deben esperar respuestas nodos (numeros provisorio) 
% tal vez la lista tenga asociado al mensaje un pid del agente encargado del conteo.
% L mapa de K:I {AgentePid}
processNA(L) ->
    receive
        {generateMsg, Msg, I, P, Nodes} ->
            APid = spawn(?MODULE, tracker, [Msg, I, P, Nodes]),
            processNA(maps:put(I, APid, L));
        
        {calculateNA, I, NP, Node} -> 
            maps:get(I, L) ! {updateNA, NP, Node},
            processNA(L);
        
        {endNA, Msg, I, NA} -> 
            loop ! {recNA, Msg, I, NA},
            processNA(maps:remove(I, L));
        
        fin -> 
            maps:map((fun(_, V)-> V ! fin end), L), % Matamos a todos los trackers vivos.
            ok
    end.


ordFun({_, _, P1, Node1, _}, {_, _, P2, Node2, _}) -> 
    case P1 < P2 of
        true -> true;
        false -> 
            case P1 > P2 of
            true -> false;
            false -> Node1 < Node2
            end
    end.

pqueue(L) ->
    receive
        % Guarda un mensaje con un valor provisorio.
        {store, Msg, I, P, Node} -> 
            pqueue([{Msg, I, P, Node, prov}] ++ L);

        % Actualiza el mensaje con un valor acordado. 
        {update, Msg, I, NA} -> 
            {_, _, _, NodeO, prov} = lists:keyfind(I, 2, L),
            pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, NodeO, acord}));

        % Si es posible, realiza un pop en la queue.
        {pop, Pid} ->
            case L of
                [] -> 
                    Pid ! noMsgs,
                    pqueue([]);
                _ ->
                    Ord = lists:sort(fun ordFun/2, L),
                    First = lists:nth(1, Ord),
                    case First of
                        {_,_,_,_,acord} ->
                            Pid ! First,
                            pqueue(lists:delete(First, Ord));
                        {_,_,_,_,prov} -> %TODO tal vez hacer un wait
                            %?Dbg("[pqueue]: Primer mensaje con estado prov reitero~n"),
                            self() ! {pop, Pid},
                            pqueue(Ord)
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
            % Puede llegar en alguna ocasion ser necesario aumentar el P. Si es necesario, no sabemos.
            queue ! {store, Msg, I, P, node()},
            receiver ! {generateMsg, Msg, I, P, nodes()},
            lists:foreach(fun (X) ->
                          {loop, X} ! {reqNP, Msg, I, node()} end,
                          nodes()),
            isisLoop(A, P, N + 1);
        
        % Dado un nuevo mensaje, lo guarda en la queue
        % y responde al emisor el numero provisorio
        {reqNP, Msg, I, Node} -> 
            NP = erlang:max(A, P) + 1,
            queue ! {store, Msg, I, NP, Node},
            {receiver, Node} ! {calculateNA, I, NP, node()},
            isisLoop(A, NP, N);

        % Dado el numero definitivo calculado por el 
        % agente actualiza el valor de la queue y del
        % nodo y manda este nuevo valor a los nodos.
        {recNA, Msg, I, NA} ->
            queue ! {update, Msg, I, NA},
            lists:foreach(fun (X) ->
                          {loop, X} ! {updNA, Msg, I, NA} end,
                          nodes()),
            isisLoop(erlang:max(A, NA), P, N);

        % Actualiza el valor acordado en la queue y en el nodo 
        {updNA, Msg, I, NA} ->
            queue ! {update, Msg, I, NA},
            isisLoop(erlang:max(A, NA), P, N);
        
        fin -> ok
    end.
