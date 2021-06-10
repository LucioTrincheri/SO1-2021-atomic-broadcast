-module(isis).
%% Funciones de control
-export([start/0, stop/0]).
%% Librería de acceso.
-export([broadcast/1, get/0]).


start () ->
    register(loop, spawn(?MODULE, isisLoop, [0,0,0])),
    register(queue, spawn(?MODULE, pqueue, [])),
    register(receiver, spawn(?MODULE, processNA, [])).

stop()->
    loop ! fin,
    unregister(loop),
    ok.

get () ->
    loop ! {getMsg, self()}
    ok.

broadcast(Msg) ->
    loop ! {getNP, Msg},
    receive ->
        MsgR -> MsgR.







% Lista de mensajes que deben esperar respuestas nodos (numeros provisorio) 
% tal vez la lista tenga asociado al mensaje un pid del agente encargado del conteo.
processNA(L) ->
    receive
        {generateMsg, Msg, I, P, Nodes} -> % Nuevo mensaje. Lo mete al parametro. Si Nodes es vacio o timeout mandar P
        {calculateNA, I, NP, node()} -> % Agarra el mensaje por identificador, calcula el max NP P, saca nodo de Nodes. Si nodes vacio devielve P y los nodos a quien mandarselo.
        %! Ver como hacer para realizar un timeout en la espera
        %! de los numeros provisorios y como hacer que funcione por mensaje

recpPrio(I, [], Pmax) ->
    loop ! {defin, Pmax};
recpPrio(I, Nodes, Pmax) ->  
    receive -> 
        {} 
        recpPrio (I, Nr-1, Pmax = max(Pmax + ))
    after 2000
    checkear si estan vivos los que quedan.
    si nadie esta vivo

pqueue(L) ->
    receive
        % Guarda un mensaje con un valor provisorio.
        {store, Msg, I, P} -> 
            pqueue({Msg, I, P, prov} | L);

        % Actualiza el mensaje con un valor acordado. 
        {update, Msg, I, NA} -> 
            pqueue(lists:keyreplace(I, 2, L, {Msg, I, NA, acord}));

        % Si es posible, realiza un pop en la queue.
        {get, I, Pid} ->
            First = lists:nth(1, lists:keysort(3, L)),
            Pid ! First, %! Ver porque el 1ro de la lista puede estar como "prov"
            pqueue(list:delete(First, L));
        fin -> ok
    end.

isisLoop (A, P, N) ->
    receive ->
        % Dado el identificador del nuevo mensaje y los 
        % nodos de los cuales esperar respuesta, guarda
        % el mensaje en la queue y crea un nuevo agente
        % que espera el numero provisorio de cada nodo  
        {getNP, Msg} -> 
            I = node() ++ integer_to_list(N),
            Nodes = nodes(),
            queue ! {store, Msg, I, P},
            receiver ! {Msg, I, P, Nodes}
            lists:foreach(fun (X) ->
                          {loop, X} ! {reqNP, Msg, I, node()}, end,
                          Nodes),
            isisLoop(A, P, N + 1);
        
        % Dado un nuevo mensaje, lo guarda en la queue
        % y responde al emisor el numero provisorio
        {reqNP, Msg, I, Node} -> 
            NP = max([A, P]) + 1,
            queue ! {store, Msg, I, NP},
            {receiver, Node} ! {calculateNA, I, NP, node()},
            isisLoop(A, NP, N);

        % Dado el numero definitivo calculado por el 
        % agente actualiza el valor de la queue y del
        % nodo y manda este nuevo valor a los nodos.
        {recNA, Msg, I, NA, Nodes} ->
            queue ! {update, Msg, I, NA},
            lists:foreach(fun (X) ->
                          {loop, X} ! {updNP, Msg, I, node(), NA}, end,
                          Nodes),
            isisLoop(max([A, NA]), P, N);

        % Actualiza el valor acordado en la queue y en el nodo 
        {updNA, Msg, I, Node, NA} ->
            queue ! {update, Msg, I, NA},
            isisLoop(max([A, NA]), P, N);
        fin -> ok
    end.
%? Como node() va dentro del identificador (I), puede ser borrado si queremos.


pqueue () ->
    .