% how to use
% change fdsafdsafsadsa.homeip.net to the right thing
% C1 = taclient:connect().
% S = fun(X) -> taclient:say(C1, X) end.
% now you can type S("blah blah"). to say "blah blah"

-module(taclient).
-export([connect/0, connect/2, say/2, close/1]).

connect() ->
	connect("192.168.0.116", 23).

connect(Server, Port) ->
	case gen_tcp:connect(Server, Port, [list, inet, {packet, raw}], 3000) of
		{ok, Socket} ->	{ok, Socket, connect_receiver(Socket)};
		{error, Reason} -> {error, Reason}
	end.
	
say(ConnectRecord, Data) ->
	{ok, Socket, _} = ConnectRecord,
	gen_tcp:send(Socket, Data ++ "\r\n").

close(ConnectRecord) ->
	{ok, Socket, ReceiverPID} = ConnectRecord,
	ReceiverPID ! die,
	gen_tcp:close(Socket).

receiver(Socket) ->
	receiver(Socket, "", spawn(fun writer/0)).

receiver(Socket, Log, Writer) ->
	receive
		{tcp, Socket, Data} ->
			Writer ! {write, Data},
			receiver(Socket, Log ++ Data, Writer);
		{tcp_closed, Socket} ->
			Writer ! {write, "Connection lost.\r\n"},
			receiver(Socket, Log, Writer);
		die ->
			Writer ! die,
			ok;
		{get_log, Sender} ->
			Sender ! {log, Log},
			receiver(Socket, Log, Writer)
	end.

writer() ->
	writer(ok).

writer(State) ->
	receive
		{write, Data} ->
			writer(print_out(Data, State, ""));
		die ->
			ok
	end.

print_out([], State, Text) ->
	io:format("~sEnd Data~n", [Text]),
	gproc:send({p,l, ws},{self(),ws,unicode:characters_to_binary(Text)}),
	State;
print_out([27 | Tail], ok, Text) ->
	print_out(Tail, midst, Text);
print_out([Head | Tail], ok, Text) ->
	print_out(Tail, ok, Text ++ [Head]);
print_out([109 | Tail], midst, Text) ->
	print_out(Tail, ok, Text);
print_out([_ | Tail], midst, Text) ->
	print_out(Tail, midst, Text).

connect_receiver(Socket) ->
	Receiver = spawn(fun() -> receiver(Socket) end),
	gen_tcp:controlling_process(Socket, Receiver),
	Receiver.