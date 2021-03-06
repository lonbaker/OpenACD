%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at fusedsolutions dot com>
%%

%% @doc Helper module for freeswitch media to ring to an agent.
-module(freeswitch_ring).
-author("Micah").

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("queue.hrl").
-include("call.hrl").
-include("agent.hrl").


%% API
-export([
	start_link/6,
	start/6,
	start_link/7,
	start/7,
	hangup/1,
	get_uuid/1
	]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3, format_status/2]).

-record(state, {
	cnode :: atom(),
	uuid :: string(),
	agent_pid :: pid(),
	callrec :: #call{},
	options = [] :: [any()]
	}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
-spec(start/6 :: (Fnode :: atom(), Agent :: string(), Apid :: pid(), Call :: #call{}, Ringout :: pos_integer(), Fun :: fun()) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start(Fnode, Agent, Apid, Call, Ringout, Fun) when is_pid(Apid), is_record(Call, call) ->
	gen_server:start(?MODULE, [Fnode, Agent, Apid, Call, Ringout, Fun, []], []).

-spec(start_link/6 :: (Fnode :: atom(), Agent :: string(), Apid :: pid(), Call :: #call{}, Ringout :: pos_integer(), Fun :: fun()) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start_link(Fnode, Agent, Apid, Call, Ringout, Fun) when is_pid(Apid), is_record(Call, call) ->
	gen_server:start_link(?MODULE, [Fnode, Agent, Apid, Call, Ringout, Fun, []], []).

-spec(start/7 :: (Fnode :: atom(), Agent :: string(), Apid :: pid(), Call :: #call{}, Ringout :: pos_integer(), Fun :: fun(), Options :: [any()]) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start(Fnode, Agent, Apid, Call, Ringout, Fun, Options) when is_pid(Apid), is_record(Call, call) ->
	gen_server:start(?MODULE, [Fnode, Agent, Apid, Call, Ringout, Fun, Options], []).

-spec(start_link/7 :: (Fnode :: atom(), Agent :: string(), Apid :: pid(), Call :: #call{}, Ringout :: pos_integer(), Fun :: fun(), Options :: [any()]) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start_link(Fnode, Agent, Apid, Call, Ringout, Fun, Options) when is_pid(Apid), is_record(Call, call) ->
	gen_server:start_link(?MODULE, [Fnode, Agent, Apid, Call, Ringout, Fun, Options], []).

-spec(hangup/1 :: (Pid :: pid()) -> 'ok').
hangup(Pid) ->
	gen_server:cast(Pid, hangup).

-spec(get_uuid/1 :: (Pid :: pid()) -> string()).
get_uuid(Pid) ->
	gen_server:call(Pid, get_uuid).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Fnode, Agent, Apid, Call, Ringout, Fun, Options]) when is_record(Call, call) ->
	case freeswitch:api(Fnode, create_uuid) of
		{ok, UUID} ->
			{CallerName, CallerNumber} = Call#call.callerid,
			Args = "[origination_caller_id_name='"++re:replace(CallerName, "'", "", [{return, list}])++"',origination_caller_id_number="++CallerNumber++",hangup_after_bridge=true,origination_uuid=" ++ UUID ++ ",originate_timeout=" ++ integer_to_list(Ringout) ++ "]user/" ++ re:replace(Agent, "@", "_", [{return, list}]) ++ " &park()",
			?INFO("originating ring channel with args: ~p", [Args]),
			case freeswitch:bgapi(Fnode, originate, Args, Fun(UUID)) of
				ok ->
					Gethandle = fun(Recusef, Count) ->
						?DEBUG("Counted ~p", [Count]),
						case freeswitch:handlecall(Fnode, UUID) of
							{error, badsession} when Count > 10 ->
								{error, badsession};
							{error, badsession} ->
								timer:sleep(100),
								Recusef(Recusef, Count+1);
							{error, Other} ->
								{error, Other};
							Else ->
								Else
						end
					end,
					case Gethandle(Gethandle, 0) of
						{error, badsession} ->
							?ERROR("bad uuid ~p when calling ~p", [UUID, Agent]),
							{stop, normal};
						{error, Other} ->
							?ERROR("other error starting; ~p for ~p", [Other, Agent]),
							{stop, normal};
						_Else ->
							?DEBUG("starting for ~p", [UUID]),
							{ok, #state{cnode = Fnode, uuid = UUID, agent_pid = Apid, callrec = Call, options = Options}}
					end;
				Else ->
					?ERROR("bgapi call failed ~p  when calling ~p", [Else, Agent]),
					{stop, normal}
			end
	end.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(get_uuid, _From, #state{uuid = UUID} = State) ->
	{reply, UUID, State};
handle_call(Request, _From, State) ->
	Reply = {unknown, Request},
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(hangup, #state{uuid = UUID} = State) ->
	freeswitch:sendmsg(State#state.cnode, UUID,
		[{"call-command", "hangup"},
			{"hangup-cause", "NORMAL_CLEARING"}]),
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({call, {event, [UUID | _Rest]}}, #state{uuid = UUID} = State) ->
	?DEBUG("call", []),
	{noreply, State};
handle_info({call_event, {event, [UUID | Rest]}}, #state{options = Options, uuid = UUID} = State) ->
	Event = proplists:get_value("Event-Name", Rest),
	Continue = case lists:keysearch(eventfun, 1, Options) of
		{value, {eventfun, Fun}} when is_function(Fun) ->
			case Fun(UUID, Event, Rest) of
				Fun2 when is_function(Fun2) ->
					Fun2();
				_ ->
					true
			end;
		_ ->
			true
	end,
	case Continue of
		true ->
			case Event of
				"CHANNEL_ANSWER" ->
					case proplists:get_value(single_leg, State#state.options) of
						true ->
							?INFO("Call with single leg answered", []),
							Call = State#state.callrec,
							try gen_media:oncall(Call#call.source) of
								invalid ->
									freeswitch:api(State#state.cnode, uuid_park, Call#call.id),
									{stop, normal, State};
								ok ->
									{noreply, State}
							catch
								exit:{noproc, _} ->
									?WARNING("~p died before I could complete the bridge", [Call#call.source]),
									% prolly get no such channel, but just in case it still lives.
									freeswitch:api(State#state.cnode, uuid_park, Call#call.id),
									{stop, normal, State}
							end;
						_ ->
							{noreply, State}
					end;
				"CHANNEL_BRIDGE" ->
					case proplists:get_value(no_oncall_on_bridge, State#state.options) of
						true ->
							{noreply, State};
						_ ->
							?INFO("Call bridged", []),
							Call = State#state.callrec,
							try gen_media:oncall(Call#call.source) of
								invalid ->
									freeswitch:api(State#state.cnode, uuid_park, Call#call.id),
									{stop, normal, State};
								ok ->
									{noreply, State}
							catch
								exit:{noproc, _} ->
									?WARNING("~p died before I could complete the bridge", [Call#call.source]),
									% prolly get no such channel, but just in case it still lives.
									freeswitch:api(State#state.cnode, uuid_park, Call#call.id),
									{stop, normal, State}
							end
					end;
				"CHANNEL_UNBRIDGE" ->
					%cdr:hangup(State#state.callrec, agent),
					{noreply, State};
				"CHANNEL_HANGUP" ->
					%AState = agent:dump_state(State#state.agent_pid),
%					case AState#agent.state of
%						oncall ->
%							?NOTICE("Agent ~s still oncall when ring channel hungup", [AState#agent.login]),
%							ok;
%						_ ->
%							ok
%					end,
					{noreply, State};
				_Else ->
					%?DEBUG("call_event ~p", [Event]),
					{noreply, State}
			end;
		ReturnVal ->
			ReturnVal
	end;
handle_info(call_hangup, State) ->
	?DEBUG("Call hangup info", []),
	{stop, normal, State};
handle_info(Info, State) ->
	?DEBUG("unhandled info ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
	?NOTICE("FreeSWITCH ring channel teminating ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

format_status(normal, [PDict, State]) ->
	[{data, [{"State", format_status(terminate, [PDict, State])}]}];
format_status(terminate, [_PDict, #state{callrec = Call} = State]) ->
	Client = Call#call.client,
	State#state{callrec = Call#call{client = Client#client{options = []}}}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
