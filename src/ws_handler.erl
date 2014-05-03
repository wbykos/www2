-module(ws_handler).
-behaviour(cowboy_websocket_handler).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

init({tcp, http}, _Req, _Opts) ->
 	io:format("Init 1: ~n", []),
	gproc:reg({p,l, ws}),
	{upgrade, protocol, cowboy_websocket}.

websocket_init(_TransportName, Req, _Opts) ->
        io:format("Init 2: ~n", []),
	{ok, Req, undefined_state}.

websocket_handle({text, Msg}, Req, State) ->
	io:format("Handle 1: ~p~n", [Msg]),
	case {text, lists:sublist(erlang:binary_to_list(Msg),5)} of
		{text, "11112"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 11112}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "11113"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 11113}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "11114"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 11114}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "11115"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 11115}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		{text, "11116"} ->
			gproc:unreg({p,l, ws}),
			gproc:reg({p,l, 11116}),
			{reply,	{text, << " got ", Msg/binary >>}, Req, State};
		_ ->
			{reply,	{text, << "Nothing to respond ", Msg/binary >>}, Req, State}
	end;
websocket_handle(_Data, Req, State) ->
	{ok, Req, State}.

websocket_info(Info, Req, State) ->
	%% io:format("Info 1: ~n", []),
	case Info of
		{_PID, _Ws, _Msg} ->
			{reply,{text, _Msg}, Req, State, hibernate};
		_ ->
			{ok, Req, State, hibernate}
	end.


websocket_terminate(_Reason, _Req, _State) ->
	ok.

%%gproc:send({p,l, ws},{self(),ws,"k"}).