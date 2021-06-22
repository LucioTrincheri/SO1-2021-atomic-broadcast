-module(isis).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([broadcast/1, pop/0]).
%% Funciones internas del programa, en orden de dependencias.
-export([isisLoop/3, pqueue/1, processNA/1]).
-export([tracker/4, ordFun/2, accordedTracker/4]).

% Constante de tiempo tras la cual se procede a verificar los nodos vivos. 
-define(TIEMPO, 100).
-define(TIEMPO_A_ESPERAR, 300).
-define(Dbg(Str),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME])).
-define(Dbg(Str,Args),io:format("[DBG]~p:" ++ Str,[?FUNCTION_NAME|Args])).

% start | stop: encargadas de comenzar y detener los agentes.
start() ->
    register(loop, spawn(?MODULE, isisLoop, [0,0,0])),
    register(queue, spawn(?MODULE, pqueue, [[]])),
    register(receiver, spawn(?MODULE, processNA, [maps:new()])),
    register(accorded, spawn(?MODULE, accordedTracker, [[], [], 0, 0])),
    ok.

stop()->
    loop ! fin,
    queue ! fin,
    receiver ! fin,
    accorded ! fin,
    unregister(loop),
    unregister(queue),
    unregister(receiver),
    unregister(accorded),
    ok.

% Funcion encargada de retirar el primer mensaje de la lista de
% mensajes. En caso que no haya mensajes, retorna un átomo acorde.
pop() ->
    queue ! {pop, self()},
    receive
        noMsgs -> 
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
            % Matamos a todos los trackers vivos.
            maps:map((fun(_, V)-> V ! fin end), L),
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

% Historial de mensajes que ya fue acordado.
% Además se encarga de devolver el estado en común de un mensaje de la red.
% La idea y para que se realizo se detallará en el informe ya que es densa la explicación. 
accordedTracker(L, Nodes, I, PId) ->
    receive
        % Recibe una nueva solicitud de computar el estado común de un mensaje.
        {computeStatus, PId, Imsg} ->
            lists:foreach(fun (X) ->
                          {accorded, X} ! {reqStatus, Imsg, node()} end,
                          nodes()),
            accordedTracker(L, nodes(), Imsg, PId);

        % Pedido de estado de un mensaje en específico.
        {reqStatus, Imsg, Node} ->
            case lists:keyfind(Imsg, 1, L) of
                {_, P} -> 
                    {accorded, Node} ! {msgStatus, acord, P, Imsg};
                false -> 
                    {accorded, Node} ! {msgStatus, noAcord, node(), Imsg}
            end,
            accordedTracker(L, Nodes, I, PId);

        % Para las respuestas, seguimos como invariante que si la 
        % lista de nodos esta vacia ya se encontro un resultado.

        % Comportamiento al recibir una respuesta positiva de estado.
        {msgStatus, acord, P, I} ->
            case Nodes of
                % Ya recibimos una respuesta valida para este I, ignoramos
                [] -> 
                    accordedTracker(L, Nodes, I, PId);
                % En otro caso, esta es la primera respuesta. Devolvemos
                _ ->
                    PId ! {statusAcord, I, P},
                    accordedTracker(L, [], I, PId)
            end;
        
        % Comportamiento al recibir una respuesta negativa de estado.
        {msgStatus, noAcord, Node, I} ->
            case Nodes of
                % Ya recibimos una respuesta valida para este I, ignoramos
                [] -> 
                    accordedTracker(L, Nodes, I, PId);
                Nodes ->
                    % Si es la ultima respuesta y no se encontro un valor
                    % acordado, se devuelve el átomo correspondiente.
                    Resto = lists:delete(Node, Nodes),
                    case Resto of
                        [] -> 
                            PId ! statusNoAcord;
                        _ -> 
                            accordedTracker(L, Resto, I, PId)
                    end
            end;
        
        % En este caso, no se pudo matchear con el I actual. Esto esta para borrar la inbox del agente.
        {msgStatus, _, _, _} ->
            accordedTracker(L, Nodes, I, PId);

        % Pedido de almacenar un nuevo mensaje acordado.
        {storeAccorded, I, P} ->
            accordedTracker(L ++ [{I, P}], Nodes, I, PId);

        fin -> ok
    after 
        % Si algun nodo muere mientras se espera la respuesta, despues de un tiempo verificamos si estan vivos aun.
        % Vale aclarar que va a haber un caso muy específico que llega a un estado de inconsistencia. Se desarrolla en el informe.
        ?TIEMPO ->
            accordedTracker(L, lists:filter(fun(Nodo) -> lists:member(Nodo, nodes()) end, Nodes), I, PId)  
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
            accorded ! {storeAccorded, I, NA},
            case lists:keyfind(I, 2, L) of
                {_, _, _, NodeO, prov} -> 
                    pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, NodeO, acord}));
                false -> 
                    pqueue(L)
            end;

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
                        % En el caso que solo le haya llegado la confirmacion a algunos
                        % de los nodos, el ISIS queda en un estado inconsistente.
                        {_,_,_,_,acord} ->
                            % Si el primer mensaje tiene valor acordado, lo devuelvo.
                            Pid ! First,
                            pqueue(lists:delete(First, Ord));
                        {Msg,I,_,Node,prov} ->
                            % Si el primer mensaje no tiene valor acordado, compruebo
                            % el estado de liveness del nodo emisor del mismo.
                            case lists:member(Node, nodes()) of
                                % Si esta vivo sigo esperando respuesta.
                                true -> 
                                    self() ! {pop, Pid},
                                    pqueue(Ord);
                                % Para mantener las propiedades de "Validity" y "Uniform Agreement", si un mensaje
                                % tiene estado provisorio y su emisor esta muerto, antes de eliminarlo se procede a
                                % preguntarle al resto de los nodos de la red si alguno tiene el valor acordado para
                                % el mensaje en cuaestión. Si lo posee, puedo actualizar el valor del mensaje. Si 
                                % nadie posee este valor, significa que el nodo emisor nunca mando confirmación. Lo borro.
                                false ->
                                    % Hacer un pequeño wait aca puede ayudar a que el número acordado le llegue primero a algun nodo de la red.
                                    timer:sleep(?TIEMPO_A_ESPERAR),
                                    accorded ! {computeStatus, self(), I},
                                    receive
                                        % Si algun nodo tiene un valor acordado se actualiza el mensaje con este valor.
                                        {statusAcord, I, ValorFinal} ->
                                            self() ! {update, Msg, I, ValorFinal},
                                            self() ! {pop, Pid},
                                            pqueue(Ord);
                                        % Significa que nadie tiene el valor acordado para este mensaje por lo tanto se lo desestima.
                                        statusNoAcord ->
                                            self() ! {pop, Pid},
                                            pqueue(lists:delete(First, Ord))
                                    end
                            end
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
                          nodes()),
            isisLoop(erlang:max(A, NA), P, N);

        % Actualiza el valor acordado en la queue.
        {updNA, Msg, I, NA} ->
            queue ! {update, Msg, I, NA},
            isisLoop(erlang:max(A, NA), P, N);
        
        fin -> ok
    end.
