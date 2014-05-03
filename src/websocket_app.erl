%% Feel free to use, reuse and abuse the code in this file.
%%
%%
%% @PRIVATE

-module(websocket_app).
-behaviour(application).
-include_lib("kernel/include/file.hrl").

-define(ControlPort, 11111).
-define(DstIp, "1.2.4.2").
-define(AvailablePorts, [11112,11113,11114,11115,11116]).
-define(PacketSize, 1408).
-define(ToDoFolder,"c:/f1").
-define(CompletedFolder,"c:/f2").

-export([start/2, stop/1, dir_loop/0, file_loop/0, file_prep/0, read_loop/0,overhead/2,move_and_clean/1]).

%% API.
start(_Type, _Args) ->
	ets:new(files, [public, named_table]),
	ets:new(program, [public, named_table]),
	register(dir_loop, spawn(fun() -> dir_loop() end)),
	register(file_loop, spawn(fun() -> file_loop() end)),
	case gen_udp:open(?ControlPort, [binary,{active, false}]) of
		{ok, CtrlSocket} ->
			ets:insert(program, {data,{coontrol_socket,CtrlSocket}}),
			io:format("Success open control socket ~p~n",[CtrlSocket]);
		{error, Reason} ->
			io:format("Error open control socket ~p~n",[Reason]),
			exit(socket_needed)
	end,
	
	Dispatch = cowboy_router:compile([
		{'_', [
			{"/", cowboy_static, [
				{directory, {priv_dir, websocket, []}},
				{file, <<"index.html">>},
				{mimetypes, [{<<".html">>, [<<"text/html">>]}]}
			]},
			{"/websocket", ws_handler, []},
			{"/static/[...]", cowboy_static, [
				{directory, {priv_dir, websocket, [<<"static">>]}},
				{mimetypes, [{<<".js">>, [<<"application/javascript">>]}]}
			]}
		]}
	]),
	{ok, _} = cowboy:start_http(http, 100, [{port, 80}],
		[{env, [{dispatch, Dispatch}]}]),
	websocket_sup:start_link().

%% Point: Periodic scan files in ToDoFolder
dir_loop() ->
	receive
		stop ->
			void;
		_ ->
			dir_loop()
		after 3000 ->
			case ets:info(files, size) of
				0 ->	
					NumFiles = filelib:fold_files( ?ToDoFolder,".*",true,
								fun(File2, Acc) ->
									%%io:format("Files ~p~n", [File2]), 
									ets:insert(files, {File2, {status,none}}),
									Acc + 1
					end, 0),
					io:format("Files added ~p~n", [NumFiles]);
				NumFiles ->
					io:format("No re-read dir, because files in work: ~p~n", [NumFiles])
			end
			%% dir_loop()
end.

%% Point: Periodic scan files in file table
file_loop() ->
	receive
		stop ->
			void
		after 1000 ->
			case ets:match(files, {'$1',{status, none}},1) of
				{[[File]],_} ->
					io:format("Start preparation for file: ~p~n", [File]),
					ets:insert(files, {File,{status, preparation}}),
					Pid = spawn(fun() -> file_prep() end),
					Pid ! {filename, File};
				_ ->
					void
			end,
			%% io:format("File table content: ~p~n",[ets:match(files, '$1')]),
			%%ets:insert(files, {Fi,ttt}),
			file_loop()
end.

%% Point: Spawn read_loop fun, and before this, look over nonbusy ports
%% Awarness: Posible delay queue on busy ports
file_prep() ->
	receive
		stop ->
			exit(omg);
		{filename, File} ->
			Pid = spawn(fun() -> read_loop() end),
			lists:foreach(fun(E) -> E end, 
			lists:takewhile(fun(E) -> case gen_udp:open(E, [binary,{active, false}]) of 
											{ok, Socket} ->
												io:format("Success test socket with port: ~p~n",[E]),
												gen_udp:close(Socket),
												ets:insert(files, {File,{status,reading},{pid,Pid},{port,E}}),
												false;
											{error, Reason} ->
												io:format("Could not open port: ~p, reason: ~p~n",[E,Reason]),
												true;
											_ ->
												true
										end
				 						end, ?AvailablePorts)),
			Pid ! {start,File};
		Any ->
			io:format("file_work error... ~p~n",[Any])
	end.
%% Point: Send chunk of file through websocket and udp then close and others...
%% Awarness: Selfexit from fun on error opening file, for delay them
read_loop() ->
	receive
		{ok,Device,CRC,Socket,Port,Sequence} ->
			case file:read(Device, ?PacketSize) of
				{ok, Data} -> 
					NewSequence = Sequence + 1,
					NewCRC = erlang:crc32(CRC, Data),
					{ok, OverHead} = overhead(NewSequence,NewCRC),
					gproc:send({p,l, Port},{self(),Port, integer_to_list(?PacketSize)}),
					gen_udp:send(Socket,?DstIp,Port,<<OverHead/binary,Data/binary>>),
					self() ! {ok,Device,NewCRC,Socket,Port,NewSequence},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
							%% io:format("Close file.~n"),
							gen_udp:send(CtrlSocket,?DstIp,?ControlPort,list_to_binary(integer_to_list(CRC))),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ok = move_and_clean(FileToClose),
									io:format("Success close file, checksum is: ~p~n",[CRC]),
									%% gproc:send({p,l, ws},{self(),ws,"checksum " ++ io_lib:format("~p",[CRC])}),
									%% gproc:send({p,l, 11112},{self(),11112,"checksum " ++ io_lib:format("~p",[CRC])});
									%% gproc:send({p,l,Port},{self(),Port, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[CRC])}),
									gproc:send({p,l,ws},{self(),ws, "close port " ++  io_lib:format("~p",[Port]) ++ " checksum " ++ io_lib:format("~p",[CRC])});
								['$end_of_table'] ->
									io:format("Error. No file to close.~n")
							end;
						AnyFileErr ->
							io:format("Error close file: ~p~n", [AnyFileErr]),
							exit(error_eof)
					end,
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close data socket: ~p~n",[Socket]),
							exit(all_good);
						AnyUdpErr ->
							io:format("Error close data socket: ~p~n",[AnyUdpErr])
					end;
				ReadError -> 
					 io:format("Error reading: ~p~n", [ReadError]),
					 exit(read_error)
			end;
		{start,File} ->
			Device = case file:open(File, [read,raw,binary]) of
						{ok, FileDevice} ->
							FileDevice;
						FileOpenError ->
							io:format("Retry. Can't open file ~p Error: ~p~n",[File, FileOpenError]),
							ets:delete(files,File),
							exit(cant_open_file)
						end,
			Filesize = case file:read_file_info(File) of
				{ok, FileData} ->
					io:format("Success read file_info: ~p Size: ~p~n", [File, FileData#file_info.size]),
					FileData#file_info.size;
				FileReadInfoError ->
					io:format("Retry. Can't read file_info: ~p Error: ~p~n", [File, FileReadInfoError]),
					ets:delete(files,File),
					exit(file_read_info_error)
			end,
			[{_,{_,CtrlSocket}}] = ets:lookup(program, data),
			[{_, {status,reading},{pid,_},{port,Port}}] = ets:lookup(files,File),
			{ok, Socket} = gen_udp:open(Port, [binary,{active, false}]),
			gen_udp:send(CtrlSocket,?DstIp,?ControlPort,term_to_binary({File,Filesize})),
			gproc:send({p,l, ws},{self(),ws,"file " ++ io_lib:format("~p",[File])}),
			gproc:send({p,l, ws},{self(),ws,"size " ++ io_lib:format("~p",[Filesize])}),
			gproc:send({p,l, ws},{self(),ws,"port " ++ io_lib:format("~p",[Port])}),
			case file:read(Device, ?PacketSize) of
				{ok, Data} -> 
					%% io:format("Send data sock~p~n",[Data]),
					CRC = erlang:crc32(Data),
					{ok, OverHead} = overhead(1,CRC),
					gen_udp:send(Socket,?DstIp,Port,<<OverHead/binary,Data/binary>>),
					self() ! {ok,Device,CRC,Socket,Port,1},
					read_loop();
				eof ->
					case file:close(Device) of
						ok ->
							gen_udp:send(CtrlSocket,?DstIp,?ControlPort,"empty"),
							gproc:send({p,l, ws},{self(),ws,"Empty file"}),
							case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
								{[[FileToClose]],_} ->
									ok = move_and_clean(FileToClose),
									io:format("Success close empty file.~n");
								['$end_of_table'] ->
									io:format("Error. No empty file to close.~n"),
									exit(file_read_algoritm_error)
							end;
						FileCloseError ->
							io:format("Error. Can't close empty file ~p Error: ~p~n",[File, FileCloseError]),
							ets:delete(files,File),
							exit(file_close_error)
					end,		
					case gen_udp:close(Socket) of
						ok ->
							io:format("Success close empty socket: ~p~n",[Socket]);
						UdpCloseError ->
							io:format("Error close empty socket: ~p~n",[UdpCloseError])
					end;
				FileReadError -> 
					case ets:match(files, {'$1',{status,reading},{pid,self()},{port,'_'}},1) of
						{[[FileToClose]],_} ->
							ets:delete(files,FileToClose),
							io:format("Read Error: ~p~n", [FileReadError]);
						['$end_of_table'] ->
							io:format("Error. No empty file to close.~n")
					end,
					exit(file_read_error)
			end;			
		AlgorithmError ->
			io:format("Algorithm read_loop error: ~p~n",[AlgorithmError]),
			exit(read_loop_error)
	end.

overhead(NewSequence,NewCRC) ->
	B1 = erlang:list_to_binary(erlang:integer_to_list(NewSequence)),
	case erlang:iolist_size(B1) of
		1 ->
			OverHeadSequence = <<<<"0000000">>/binary,B1/binary>>;
		2 ->
			OverHeadSequence = <<<<"000000">>/binary,B1/binary>>;
		3 ->
			OverHeadSequence = <<<<"00000">>/binary,B1/binary>>;
		4 ->
			OverHeadSequence = <<<<"0000">>/binary,B1/binary>>;
		5 ->
			OverHeadSequence = <<<<"000">>/binary,B1/binary>>;
		6 ->
			OverHeadSequence = <<<<"00">>/binary,B1/binary>>;
		7 ->
			OverHeadSequence = <<<<"0">>/binary,B1/binary>>;
		8 ->
			OverHeadSequence = <<B1/binary>>
	end,
	OverHeadCRC = erlang:list_to_binary(erlang:integer_to_list(NewCRC)),
	OverHeadCRCsize = erlang:list_to_binary(erlang:integer_to_list(erlang:iolist_size(OverHeadCRC))),
	case {erlang:iolist_size(OverHeadCRC) =< 9} of
		{true} ->
			OverHead = <<OverHeadSequence/binary,<<"0">>/binary, OverHeadCRCsize/binary, OverHeadCRC/binary>>;
		{false} ->
			OverHead = <<OverHeadSequence/binary,OverHeadCRCsize/binary, OverHeadCRC/binary>>
	end,
	io:format("Send data...~p~n",[OverHead]),
	{ok,OverHead}.

move_and_clean(FileToClose) ->
	FileToMove = filename:join(lists:append([?CompletedFolder],lists:nthtail(erlang:length(filename:split(?ToDoFolder)),filename:split(FileToClose)))),
	filelib:ensure_dir(FileToMove),
	file:rename(FileToClose,FileToMove),
	ets:delete(files,FileToClose),
	ok.

stop(_State) ->
	ok.