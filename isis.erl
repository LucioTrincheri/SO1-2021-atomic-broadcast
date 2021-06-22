-module(isis).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([broadcast/1, pop/0]).
%% Funciones internas del programa, en orden de dependencias.
-export([isisLoop/3, pqueue/1, processNA/1]).
-export([tracker/4, ordFun/2]).
%% Función auxiliar para testing.
-export([p/1]).

% Constante de tiempo tras la cual se procede a verificar los nodos vivos. 
-define(TIEMPO, 100).
-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

% Función auxiliar para hacer testing con muchos nodos.
p(X) -> net_adm:ping(list_to_atom(X)).

% start | stop: encargadas de comenzar y detener los agentes.
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

% Funcion encargada de retirar el primer mensaje de la lista de
% mensajes. En caso que no haya mensajes, retorna un átomo acorde.
pop() ->
    queue ! {pop, self()},
    %%?Dbg("[Pop]: Esperando mensaje...~n"),
    receive
        noMsgs -> 
            %io:format("No hay mensajes nuevos~n"),
            noMsgs;
        {Msg, _, _, _, _} -> Msg
    end.

% Función accesible por el usuario. Envía al loop un pedido de broadcast.
broadcast(Msg) ->
    loop ! {getNP, Msg},
    ok.

% Agente invocado por processNA, encargado de monitorear
% un mensaje en específico. Por cada mensaje que recibe,
% actualiza el valor de prioridad y remueve el nodo emisor
% de la lista de mensajes. En el caso que no haya mas nodos
% a esperar, devuelve el resultado final de prioridad P.
% Por otra parte, se encarga de fijarse que los nodos a los
% que se esta esperando estan vivos. En caso contrario, los elimina.
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

% Agente que se encarga de invocar y destruir agentes, los cuales 
% se encargar de monitorear las respuestas de valor prioridad
% relacionadas a cada mensaje (1 mensaje monitoreado por agente)
% Ademas, redirecciona mensajes de prioridad a su agente correspondiente. 
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

% Función de ordenamiento de mensajes. Toma al valor P como primer
% valor para decidir el orden. Ante una igualdad (que se puede dar
% cuando dos nodos envian un mensaje en el mismo momento), decide
% el orden mediante el nombre del nodo emisor del mensaje original.
ordFun({_, _, P1, Node1, _}, {_, _, P2, Node2, _}) -> 
    case P1 < P2 of
        true -> true;
        false -> 
            case P1 > P2 of
            true -> false;
            false -> Node1 < Node2
            end
    end.

% Lista encargada de almacenar los mensajes con sus
% estados, actualizar los valores de prioridad de 
% los mismos y devolver mensajes si es pedido. 
pqueue(L) ->
    receive
        % Guarda un mensaje con un valor provisorio.
        {store, Msg, I, P, Node} -> 
            pqueue([{Msg, I, P, Node, prov}] ++ L);

        % Actualiza el mensaje con un valor acordado. 
        {update, Msg, I, NA} -> 
            case lists:keyfind(I, 2, L) of %! Ver que tan legal es esta linea. Sino reemplazar por '%?'.
                {_, _, _, NodeO, prov} -> 
                    pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, NodeO, acord}));
                false -> 
                    pqueue(L)
            end
            %? {_, _, _, NodeO, prov} = lists:keyfind(I, 2, L),
            %? pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, NodeO, acord}));

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

%! Bug: Si un nodo manda un mensaje solicitando numeros de prioridad, y muere antes de que les pueda
%! responder con el valor final, ese mensaje provisorio queda en la queue. Los nodos nunca van a seguir.
%TODO Sobre esto hay que arreglar dos situaciones: 
    %TODO -> El nodo emisor manda, muere antes de que lleguen respuestas. Todos tienen un mensaje provisorio.
    %TODO -> El nodo emisor manda los valores finales. Mientra los manda muere. Algunos tiene valor acordado.

%! Sigo buscando problemas.
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
        % agente actualiza el valor de la queue y 
        % manda este nuevo valor a los nodos.
        {recNA, Msg, I, NA} ->
            queue ! {update, Msg, I, NA},
            lists:foreach(fun (X) ->
                          {loop, X} ! {updNA, Msg, I, NA} end,
                          nodes()), % TODO Creo que arreglado: Problema. Tendriamos que hacer que si un nodo recibe una actualizacion, no se rompa si el mensaje no existe en su queue.
            isisLoop(erlang:max(A, NA), P, N);

        % Actualiza el valor acordado en la queue.
        {updNA, Msg, I, NA} -> %! Para arreglar el bug, puede ser necesario checkear si el que me mando el mensaje esta muerto. Si lo esta, reenvio a nodos. Si no lo esta, sigo normal.
            queue ! {update, Msg, I, NA},
            isisLoop(erlang:max(A, NA), P, N);
        
        fin -> ok
    end.
