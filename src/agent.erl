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

%% @doc A gen_fsm representing the agent's state.
-module(agent).
-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-type(agent_opt() :: {'nodes', [atom()]} | 'logging').
-type(agent_opts() :: [agent_opt()]).
-type(release_code() :: {string(), atom(), -1 | 0 | 1} | 'default').

-type(state() :: #agent{}).
-define(GEN_FSM, true).
-include("gen_spec.hrl").

-define(IDLE_LIMITS, {idle, {60 * 2, 0, 0, {time, util:now()}}}).
-define(PRECALL_LIMITS, {precall, {0, 0, 60 * 2, {time, util:now()}}}).
-define(RELEASED_LIMITS(Bias), [
	{released, {0, 0, 60 * 5, {time, util:now()}}},
	case Bias of
		-1 ->
			{bias, 60};
		0 ->
			{bias, 50};
		1 ->
			{bias, 30}
	end
]).
-define(OUTGOING_LIMITS, {outgoing, {0, 60 * 5, 60 * 15, {time, util:now()}}}).
-define(ONCALL_LIMITS, {oncall, {0, 60 * 5, 60 * 15, {time, util:now()}}}).
-define(WRAPUP_LIMITS, {wrapup, {0, 0, 60 * 5, {time, util:now()}}}).
-define(RINGING_LIMITS, {ringing, {0, 0, 60, {time, util:now()}}}).
-define(WARMTRANSFER_LIMITS, {warmtransfer, {0, 60 * 2, 60 * 5, {time, util:now()}}}).
-define(DEFAULT_REL, {"default", default, -1}).

-define(WRAPUP_AUTOEND_KEY, autoend_wrapup).
%% gen_fsm exports
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4, format_status/2]).
%% defined state exports
-export([idle/3, ringing/3, precall/3, oncall/3, outgoing/3, released/3, warmtransfer/3, wrapup/3]).
%% defining async state exports
-export([idle/2, ringing/2, precall/2, oncall/2, outgoing/2, released/2, warmtransfer/2, wrapup/2]).

%% other exports
-export([start/1,
	start/2,
	start_link/1,
	start_link/2,
	stop/1, 
	add_skills/2,
	remove_skills/2,
	change_profile/2,
	query_state/1, 
	dump_state/1, 
	get_media/1,
	set_state/2, 
	set_state/3, 
	list_to_state/1, 
	integer_to_state/1, 
	state_to_integer/1, 
	set_connection/2, 
	set_endpoint/2, 
	agent_transfer/2,
	queue_transfer/2,
	conn_cast/2,
	conn_call/2, 
	media_call/2,
	media_cast/2,
	media_push/2,
	url_pop/3,
	blab/2,
	spy/2,
	%warm_transfer_begin/2,
	%warm_transfer_cancel/1,
	%warm_transfer_complete/1,
	register_rejected/1,
	log_loop/4]).

%% @doc Start an agent fsm for the passed in agent record `Agent' that is linked
%% to the calling process with default options.
-spec(start_link/1 :: (Agent :: #agent{}) -> {'ok', pid()}).
start_link(Agent = #agent{}) ->
	start_link(Agent, []).

%% @doc Start an agent fsm for the passed in agent record `Agent' that is linked
%% to the calling process with the given options.
-spec(start_link/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start_link(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start_link(?MODULE, [Agent, Options], []).

%% @doc Start an agent fsm for the passed in agent record `Agent' with default
%% options.
-spec(start/1 :: (Agent :: #agent{}) -> {'ok', pid()}).
start(Agent = #agent{}) ->
	start(Agent, []).

%% @doc Start an agent fsm for the passed in agent record `Agent' with the given
%% options.
-spec(start/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start(?MODULE, [Agent, Options], []).

%% @doc Stop the passed agent fsm `Pid'.
-spec(stop/1 :: (Pid :: pid()) -> 'ok').
stop(Pid) -> 
	gen_fsm:send_all_state_event(Pid, stop).
	
%% @doc link the given agent  `Pid' to the given connection `Socket'.
-spec(set_connection/2 :: (Pid :: pid(), Socket :: pid()) -> 'ok' | 'error').
set_connection(Pid, Socket) ->
	gen_fsm:sync_send_all_state_event(Pid, {set_connection, Socket}).

-spec(set_endpoint/2 :: (Pid :: pid(), Endpoint :: {endpoints(), string()}) -> ok).
set_endpoint(Pid, Endpoint) ->
	gen_fsm:sync_send_all_state_event(Pid, {set_endpoint, Endpoint}).

%% @doc When the agent manager can't register an agent, it 'casts' to this.
-spec(register_rejected/1 :: (Pid :: pid()) -> 'ok').
register_rejected(Pid) ->
	gen_fsm:send_event(Pid, register_rejected).

%% @doc When the media wants to cast to the connnection.
-spec(conn_cast/2 :: (Apid :: pid(), Request :: any()) -> 'ok').
conn_cast(Apid, Request) ->
	gen_fsm:send_event(Apid, {conn_cast, Request}).

%% @doc When the media wants to call to the connection.
-spec(conn_call/2 :: (Apid :: pid(), Request :: any()) -> any()).
conn_call(Apid, Request) ->
	gen_fsm:sync_send_event(Apid, {conn_call, Request}).
	
%% @doc The connection can request to call to the agent's media when oncall.
-spec(media_call/2 :: (Apid :: pid(), Request :: any()) -> any()).
media_call(Apid, Request) ->
	gen_fsm:sync_send_event(Apid, {mediacall, Request}).

%% @doc To cast to the media while oncall, use this.
-spec(media_cast/2 :: (Apid :: pid(), Request :: any()) -> 'ok').
media_cast(Apid, Request) ->
	gen_fsm:send_event(Apid, {mediacast, Request}).

%% @private
%-spec(init/1 :: (Args :: [#agent{}]) -> {'ok', 'released', #agent{}}).
init([State, Options]) when is_record(State, agent) ->
	process_flag(trap_exit, true),
	#agent_profile{name = Profile, skills = Skills} = try agent_auth:get_profile(State#agent.profile) of
		undefined ->
			?WARNING("Agent ~p has an invalid profile of ~p, using Default", [State#agent.login, State#agent.profile]),
			agent_auth:get_profile("Default");
		Else ->
			Else
	catch
		error:{case_clause, {aborted, _}} ->
			#agent_profile{name = error}
	end,
	State2 = State#agent{skills = util:merge_skill_lists(expand_magic_skills(State, Skills), expand_magic_skills(State, State#agent.skills), ['_queue', '_brand']), profile = Profile},
	agent_manager:update_skill_list(State2#agent.login, State2#agent.skills),
	case State#agent.state of
		idle ->
			gen_server:cast(dispatch_manager, {now_avail, self()});
		_Other ->
			gen_server:cast(dispatch_manager, {end_avail, self()})
	end,
	State3 = case proplists:get_value(logging, Options) of
		true ->
			Nodes = case proplists:get_value(nodes, Options) of
				undefined ->
					case application:get_env(cpx, nodes) of
						{ok, N} -> N;
						undefined -> [node()]
					end;
				Orelse -> Orelse
			end,
			Pid = spawn_link(agent, log_loop, [State#agent.id, State#agent.login, Nodes, State#agent.profile]),
			Pid ! {State#agent.login, login, State#agent.state, State#agent.statedata},
			State2#agent{log_pid = Pid};
		_Orelse ->
			State2
	end,
	set_cpx_monitor(State3, ?RELEASED_LIMITS(-1), [{reason, default}, {bias, -1}]),
	{ok, State#agent.state, State3#agent{start_opts = Options}}.

% actual functions we'll call
%% @private
-spec(expand_magic_skills/2 :: (State :: #agent{}, Skills :: [atom()]) -> [atom()]).
expand_magic_skills(State, Skills) ->
	lists:map(
		fun('_agent') -> {'_agent', State#agent.login};
		('_node') -> {'_node', node()};
		('_profile') -> {'_profile', State#agent.profile};
		(Skill) -> Skill
	end, Skills).

%% @doc Returns the entire agent record for the agent at `Pid'.
-spec(dump_state/1 :: (Pid :: pid()) -> #agent{}).
dump_state(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, dump_state).

%% @doc Returns the #call{} of the current state if there is on, otherwise 
%% returns `invalid'.
-spec(get_media/1 :: (Apid :: pid()) -> {ok, #call{}} | 'invalid').
get_media(Apid) ->
	gen_fsm:sync_send_event(Apid, get_media).

-spec(add_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
add_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {add_skills, Skills}).

-spec(remove_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
remove_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {remove_skills, Skills}).

-spec(change_profile/2 :: (Apid :: pid(), Profile :: string()) -> 'ok' | {'error', 'unknown_profile'}).
change_profile(Apid, Profile) ->
	gen_fsm:sync_send_all_state_event(Apid, {change_profile, Profile}).

%% @doc Returns `{ok, Statename :: atom()}', where `Statename' is the current state of the agent at `Pid'.
-spec(query_state/1 :: (Pid :: pid()) -> {'ok', atom()}).
query_state(Pid) -> 
	gen_fsm:sync_send_all_state_event(Pid, query_state).

%% @doc Attempt to set the state of agent at `Pid' to `State'.
-spec(set_state/2 :: (Pid :: pid(), State :: atom()) -> 'ok' | 'invalid').
set_state(Pid, State) ->
	gen_fsm:sync_send_event(Pid, State).

%% @doc Attempt to set the state of the agent at `Pid' to `State' with data `Data'.  `Data' is related to the `State' the agent is going into.  
%% Often `Data' will be `#call{} or a callid of type `string()'.
-spec(set_state/3 :: (Pid :: pid(), State :: 'idle' | 'ringing' | 'precall' | 'oncall' | 'outgoing' | 'warmtransfer' | 'wrapup', Data :: any()) -> 'ok' | 'invalid';
                     (Pid :: pid(), State :: 'released', Data :: any()) -> 'ok' | 'invalid' | 'queued').
set_state(Pid, State, Data) ->
	gen_fsm:sync_send_event(Pid, {State, Data}).

%% @doc attmept to push data from the media connection to the agent.  It's up to
%% the agent connection to interpret this correctly.
-spec(media_push/2 :: (Pid :: pid(), Data :: any()) -> any()).
media_push(Pid, Data) ->
	S = self(),
	gen_fsm:send_event(Pid, {mediapush, S, Data}).

-spec(url_pop/3 :: (Pid :: pid(), Data :: list(), Name :: string()) -> any()).
url_pop(Pid, Data, Name) ->
	gen_fsm:sync_send_all_state_event(Pid, {url_pop, Data, Name}).

%% @doc Send a message to the human agent.  If there's no connection, it black-holes.
-spec(blab/2 :: (Pid :: pid(), Text :: string()) -> 'ok').
blab(Pid, Text) ->
	gen_fsm:send_all_state_event(Pid, {blab, Text}).

%% @doc Make the give `pid() Spy' spy on `pid() Target'.
-spec(spy/2 :: (Spy :: pid(), Target :: pid()) -> 'ok' | 'invalid').
spy(Spy, Target) ->
	gen_fsm:sync_send_event(Spy, {spy, Target}).

%% @doc Translate the state `String' into the internally used atom.  `String' can either be the human readable string or a number in string form (`"1"').
-spec(list_to_state/1 :: (String :: string()) -> atom()).
list_to_state(String) ->
	try list_to_integer(String) of
		Int -> integer_to_state(Int)
	catch
		_:_ ->
			case string:to_lower(String) of
				"idle" -> idle;
				"ringing" -> ringing;
				"precall" -> precall;
				"oncall" -> oncall;
				"outgoing" -> outgoing;
				"released" -> released;
				"warmtransfer" -> warmtransfer;
				"wrapup" -> wrapup
			end
	end.

%% @doc Start the agent_transfer procedure.  Gernally the media will handle it from here.
-spec(agent_transfer/2 :: (Pid :: pid(), Target :: pid()) -> 'ok' | 'invalid').
agent_transfer(Pid, Target) ->
	gen_fsm:sync_send_event(Pid, {agent_transfer, Target}).

%% @doc Start the queue_transfer procedure.  Gernally the media will handle it from here.
-spec(queue_transfer/2 :: (Pid :: pid(), Queue :: string()) -> 'ok' | 'invalid').
queue_transfer(Pid, Queue) ->
	gen_fsm:sync_send_event(Pid, {queue_transfer, Queue}).


%% @_doc Start the warm_transfer procedure.  Gernally the media will handle it from here.
%-spec(warm_transfer_begin/2 :: (Pid :: pid(), Target :: string()) -> 'ok' | 'invalid').
%warm_transfer_begin(Pid, Target) ->
	%gen_fsm:sync_send_event(Pid, {warm_transfer_begin, Target}).

%% @_doc Cancel the warm_transfer procedure.  Gernally the media will handle it from here.
%-spec(warm_transfer_cancel/1 :: (Pid :: pid()) -> 'ok' | 'invalid').
%warm_transfer_cancel(Pid) ->
	%gen_fsm:sync_send_event(Pid, warm_transfer_cancel).

%% @_doc Complete the warm_transfer procedure.  Gernally the media will handle it from here.
%-spec(warm_transfer_complete/1 :: (Pid :: pid()) -> 'ok' | 'invalid').
%warm_transfer_complete(Pid) ->
	%gen_fsm:sync_send_event(Pid, warm_transfer_complete).

%% @doc Translate the integer `Int' to the corresponding internally used atom.
-spec(integer_to_state/1 :: (Int :: 2) -> 'idle';
                            (Int :: 3) -> 'ringing';
                            (Int :: 4) -> 'precall';
                            (Int :: 5) -> 'oncall';
                            (Int :: 6) -> 'outgoing';
                            (Int :: 7) -> 'released';
                            (Int :: 8) -> 'warmtransfer';
                            (Int :: 9) -> 'wrapup').
integer_to_state(Int) ->
	case Int of
		2 -> idle;
		3 -> ringing;
		4 -> precall;
		5 -> oncall;
		6 -> outgoing;
		7 -> released;
		8 -> warmtransfer;
		9 -> wrapup
	end.

%% @doc Translate the interally used atom `State' to the integer equivalent.
-spec(state_to_integer/1 :: (State :: 'undefined') -> 0;
                            (State :: 'logout') -> 1;
                            (State :: 'idle') -> 2;
                            (State :: 'ringing') -> 3;
                            (State :: 'precall') -> 4;
                            (State :: 'oncall') -> 5;
                            (State :: 'outgoing') -> 6;
                            (State :: 'released') -> 7;
                            (State :: 'warmtransfer') -> 8;
                            (State :: 'wrapup') -> 9).
state_to_integer(State) ->
	case State of
		undefined -> 0;
		login -> 0;
		logout -> 1;
		idle -> 2;
		ringing -> 3;
		precall -> 4;
		oncall -> 5;
		outgoing -> 6;
		released -> 7;
		warmtransfer -> 8;
		wrapup -> 9
	end.

%% @doc The various state changes available when an agent is idle. <ul>
%%<li>`{precall, Client :: #client{}}'</li>
%%<li>`{ringing, Call :: #call{}}'</li>
%%<li>`{released, Reason :: string()}'</li>
%%</ul>
-spec(idle/3 :: (Event :: {'precall', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'precall', #agent{}};
	(Event :: {'ringing', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'ringing', #agent{}};
	(Event :: {'released',  release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'released', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'idle', #agent{}}).
idle({precall, Call}, _From, State) ->
	gen_server:cast(dispatch_manager, {end_avail, self()}),
	gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, precall, Call}),
	Newstate = State#agent{state=precall, oldstate=idle, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?PRECALL_LIMITS, []),
	{reply, ok, precall, Newstate};
idle({ringing, Call = #call{}}, _From, State) ->
	gen_server:cast(State#agent.connection, {change_state, ringing, Call}),
	gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
	Newstate = State#agent{state=ringing, oldstate=idle, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?RINGING_LIMITS, []),
	{reply, ok, ringing, Newstate};
idle({released, default}, From, State) ->
	idle({released, ?DEFAULT_REL}, From, State);
idle({released, {Id, Reason, Bias}}, _From, State) when -1 =< Bias, Bias =< 1, is_integer(Bias) ->
	gen_server:cast(dispatch_manager, {end_avail, self()}),
	gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, released, {Id, Reason, Bias}}), % it's up to the connection to determine if this is worth listening to
	Newstate = State#agent{state=released, oldstate=idle, statedata={Id, Reason, Bias}, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?RELEASED_LIMITS(Bias), [{reason, Reason}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, Newstate};
idle(Event, From, State) ->
	?WARNING("Invalid event '~p' sent from ~p while in state 'idle'", [Event, From]),
	{reply, invalid, idle, State}.

-spec(idle/2 :: (Msg :: any(), State :: #agent{}) -> {'next_state', 'idle', #agent{}}).
idle(_Message, State) ->
	{next_state, idle, State}.

%% @doc The various state changes available when an agent is ringing. <ul>
%%<li>`oncall'<br />When default ring path is `inband' and the call's ring path is not outband.</li>
%%<li>`{oncall, Call :: #call{}}'</li>
%%<li>`{released, Reason :: string()}'</li>
%%<li>`idle'</li>
%</ul>
-spec(ringing/3 :: (Event :: 'oncall', From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'oncall', #agent{}};
	(Event :: {'oncall', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'oncall', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'released', #agent{}};
	(Event :: 'idle', From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'idle', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'ringing', #agent{}}).
ringing(oncall, _From, #agent{statedata = Statecall} = State) when Statecall#call.ring_path == inband ->
	?DEBUG("default ringpath inband, ring_path not outband", []),
	case gen_media:oncall(Statecall#call.source) of
		ok ->
			Newstate = State#agent{state=oncall, oldstate = ringing, lastchange = util:now()},
			gen_server:cast(dispatch_manager, {end_avail, self()}),
			gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
			gen_server:cast(State#agent.connection, {change_state, oncall, State#agent.statedata}),
			gen_server:cast(Statecall#call.cook, remove_from_queue),
			%cdr:oncall(Statecall, State#agent.login),
			set_cpx_monitor(Newstate, ?ONCALL_LIMITS, []),
			{reply, ok, oncall, Newstate};
		invalid ->
			{reply, invalid, ringing, State}
	end;
ringing({oncall, #call{id=Callid} = Call}, _From, #agent{statedata = Statecall} = State) ->
	case Statecall#call.id of
		Callid -> 
			Newstate = State#agent{state = oncall, statedata = Call, oldstate = ringing, lastchange = util:now()},
			gen_server:cast(dispatch_manager, {end_avail, self()}),
			gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
			gen_server:cast(State#agent.connection, {change_state, oncall, Call}),
			set_cpx_monitor(Newstate, ?ONCALL_LIMITS, []),
			{reply, ok, oncall, Newstate};
		_Other -> 
			{reply, invalid, ringing, State}
	end;
ringing({released, default}, From, State) ->
	ringing({released, ?DEFAULT_REL}, From, State);
ringing({released, {Id, Text, Bias} = Reason}, _From, #agent{statedata = Call} = State) when -1 =< Bias, Bias =< 1, is_integer(Bias) ->
	?DEBUG("going released from ringing", []),
	%gen_server:cast(Call#call.cook, {stop_ringing_keep_state, self()}),
	gen_media:stop_ringing(Call#call.source),
	gen_server:cast(dispatch_manager, {end_avail, self()}),
	gen_leader:cast(agent_manager, {end_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, released, Reason}), % it's up to the connection to determine if this is worth listening to
	Newstate = State#agent{state=released, oldstate=ringing, statedata=Reason, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?RELEASED_LIMITS(Bias), [{reason, Text}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, Newstate};
ringing(idle, _From, State) ->
	gen_leader:cast(agent_manager, {now_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, idle}),
	Newstate = State#agent{state=idle, oldstate=ringing, statedata={}, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?IDLE_LIMITS, []),
	{reply, ok, idle, Newstate};
ringing(Event, _From, State) ->
	?DEBUG("ringing evnet ~p", [Event]),
	{reply, invalid, ringing, State}.

-spec(ringing/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
ringing(register_rejected, State) ->
	{stop, register_rejected, State};
ringing(_Msg, State) ->
	{next_state, ringing, State}.

%% @doc The various state changes available when an agent is in precall. <ul>
%%<li>`{outgoing, Call :: #call{}'}</li>
%%<li>`idle'</li>
%%<li>`{released, Reason}'</li>
%%</ul>
-spec(precall/3 :: (Event :: {'outgoing', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'outgoingcall', #agent{}};
	(Event :: 'idle', From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'idle', #agent{}};
	(Event :: {'released', any()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'released', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'precall', #agent{}}).
precall({outgoing, Call}, _From, #agent{statedata = StateCall} = State) when Call#call.id =:= StateCall#call.id ->
	gen_server:cast(State#agent.connection, {change_state, outgoing, Call}),
	Newstate = State#agent{state=outgoing, oldstate=State#agent.state, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?OUTGOING_LIMITS, []),
	{reply, ok, outgoing, Newstate};
precall(idle, _From, #agent{statedata = Call} = State) ->
	gen_server:cast(Call#call.source, cancel),
	gen_server:cast(dispatch_manager, {now_avail, self()}),
	gen_leader:cast(agent_manager, {now_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, idle}),
	Newstate = State#agent{state=idle, oldstate=State#agent.state, statedata={}, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?IDLE_LIMITS, []),
	{reply, ok, idle, Newstate};
precall({released, default}, From, State) ->
	precall({released, ?DEFAULT_REL}, From, State);
precall({released, {Id, Text, Bias} = Reason}, _From, #agent{statedata = Call} = State) when -1 =< Bias, Bias =< 1, is_integer(Bias) ->
	gen_server:cast(Call#call.source, cancel),
	gen_server:cast(State#agent.connection, {change_state, released, Reason}),
	Newstate = State#agent{state=released, oldstate=State#agent.state, statedata=Reason, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?RELEASED_LIMITS(Bias), [{reason, Text}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, Newstate};
precall(_Event, _From, State) -> 
	{reply, invalid, precall, State}.

-spec(precall/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
precall(register_rejected, State) ->
	{stop, register_rejected, State};
precall(_Msg, State) ->
	{next_state, precall, State}.

%% @doc The various state changes available when an agent is oncall. <ul>
%%<li>`{released, undefined}'<br />Note this 'un-queues' a released state when the call is done.</li>
%%<li>`{released, Reason :: string()}'<br />This only queues a release, it doesn't actually change state</li>
%%<li>`wrapup'<br />When the media path of the call is `inband'</li>
%%<li>`{wrapup, Call :: #call}'<br />When the media path is `outband'</li>
%%<li>`{warmtransfer, Transferto :: any()}'</li>
%%</ul>
-spec(oncall/3 :: (Event :: {'released', 'undefined'}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'oncall', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'queued', 'oncall', #agent{}};
	(Event :: 'wrapup', From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'wrapup', #agent{}};
	(Event :: {'wrapup', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'wrapup', #agent{}};
	(Event :: {'warmtransfer', any()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'warmtransfer', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'oncall', #agent{}}).
oncall({released, undefined}, _From, State) -> 
	{reply, ok, oncall, State#agent{queuedrelease=undefined}};
oncall({released, default}, From, State) ->
	oncall({released, ?DEFAULT_REL}, From, State);
oncall({released, {_Id, _Text, Bias} = Reason}, _From, State) when is_integer(Bias), -1 =< Bias, Bias =< 1 -> 
	{reply, queued, oncall, State#agent{queuedrelease=Reason}};
oncall(wrapup, _From, #agent{statedata = Call} = State) when Call#call.media_path =:= inband ->
	gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
	%cdr:hangup(Call, agent),
	%cdr:wrapup(Call, State#agent.login),
	try gen_media:wrapup(Call#call.source) of
		ok ->			
			Newstate = State#agent{state=wrapup, lastchange = util:now(), oldstate = oncall},
			set_cpx_monitor(Newstate, ?WRAPUP_LIMITS, []),
			Client = Call#call.client,
			case proplists:get_value(?WRAPUP_AUTOEND_KEY, Client#client.options) of
				N when is_integer(N) andalso N > 0 ->
					Self = self(),
					erlang:send_after(N * 1000, Self, end_wrapup);
				_ ->
					ok
			end,
			{reply, ok, wrapup, Newstate};
		invalid ->
			?WARNING("a living media replied it could not go to wrapup", []),
			{reply, invalid, oncall, State}
	catch
		exit:{noproc, _Blahblahcall} ->
			?WARNING("Seems the call died without me noticing", []),
			Newstate = State#agent{state=wrapup, lastchange = util:now(), oldstate = oncall},
			set_cpx_monitor(Newstate, ?WRAPUP_LIMITS, []),
			{reply, ok, wrapup, Newstate}
	end;
oncall({wrapup, #call{id = Callid} = Call}, _From, #agent{statedata = Currentcall} = State) ->
	case Currentcall#call.id of
		Callid -> 
			gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
			%cdr:wrapup(Call, State#agent.login),
			Newstate = State#agent{state=wrapup, statedata=Call, lastchange = util:now(), oldstate = oncall},
			set_cpx_monitor(Newstate, ?WRAPUP_LIMITS, []),
			Client = Call#call.client,
			case proplists:get_value(?WRAPUP_AUTOEND_KEY, Client#client.options) of
				N when is_integer(N) andalso N > 0 ->
					Self = self(),
					erlang:send_after(N * 1000, Self, end_wrapup);
				_ ->
					ok
			end,
			{reply, ok, wrapup, Newstate};
		_Else ->
			{reply, invalid, oncall, State}
	end;
oncall({warmtransfer, Transferto}, _From, State) ->
	StateData = {onhold, State#agent.statedata, calling, Transferto},
	gen_server:cast(State#agent.connection, {change_state, warmtransfer, StateData}),
	Newstate = State#agent{state=warmtransfer, oldstate=State#agent.state, statedata=StateData, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?WARMTRANSFER_LIMITS, []),
	{reply, ok, warmtransfer, Newstate};
oncall({agent_transfer, Agent}, _From, #agent{statedata = Call} = State) when is_pid(Agent) ->
	% TODO - why is the timeout hardcoded, any why was it only 10 seconds
	Reply = gen_media:agent_transfer(Call#call.source, Agent, 30000),
	{reply, Reply, oncall, State};
oncall({queue_transfer, Queue}, _From, #agent{statedata = Call} = State) ->
	Reply = gen_media:queue(Call#call.source, Queue),
	gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
	Newstate = State#agent{state=wrapup, oldstate=State#agent.state, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?WARMTRANSFER_LIMITS, []),
	{reply, Reply, wrapup, Newstate};
%oncall({warm_transfer_begin, Number}, _From, #agent{statedata = Call} = State) ->
	%case gen_media:warm_transfer_begin(Call#call.source, Number, self(), State) of
		%{ok, UUID} ->
			%gen_server:cast(State#agent.connection, {change_state, warmtransfer, UUID}),
			%set_cpx_monitor(State#agent{state = warmtransfer}, ?WARMTRANSFER_LIMITS, []),
			%{reply, ok, warmtransfer, State#agent{state=warmtransfer, statedata={onhold, State#agent.statedata, calling, UUID}, lastchange = util:now()}};
		%_ ->
			%{reply, invalid, oncall, State}
	%end;
oncall(get_media, _From, #agent{statedata = Media} = State) when is_record(Media, call) ->
	{reply, {ok, Media}, oncall, State};
oncall({conn_call, Request}, {Pid, _Tag}, #agent{statedata = Media} = State) ->
	case {Media#call.source, State#agent.connection} of
		{_, undefined} ->
			{reply, {error, noconnection}, oncall, State};
		{Pid, Connpid} ->
			Reply = gen_server:call(Connpid, Request),
			{reply, Reply, oncall, State};
		{_, _} ->
			{reply, invalid, oncall, State}
	end;
oncall(_Event, _From, State) -> 
	{reply, invalid, oncall, State}.

-spec(oncall/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
oncall({conn_cast, Request}, #agent{connection = Pid} = State) ->
	case is_pid(Pid) of
		true ->
			gen_server:cast(Pid, Request);
		false ->
			ok
	end,
	{next_state, oncall, State};
oncall({mediacast, Request}, #agent{statedata = Call} = State) ->
	?DEBUG("media case ~p", [Request]),
	gen_media:cast(Call#call.source, Request),
	{next_state, oncall, State};
oncall(register_rejected, #agent{statedata = Media} = State) when Media#call.media_path =:= inband ->
	gen_media:wrapup(Media#call.source),
	{stop, register_rejected, State};
oncall(register_rejected, State) ->
	{stop, register_rejected, State};
oncall({mediapush, Mediapid, Data}, #agent{statedata = Media} = State) when Media#call.source =:= Mediapid ->
	case State#agent.connection of
		undefined ->
			{next_state, oncall, State};
		Conn when is_pid(Conn) ->
			?DEBUG("shoving ~p", [Data]),
			gen_server:cast(Conn, {mediapush, Media, Data}),
			{next_state, oncall, State}
	end;
oncall(Message, State) ->
	?DEBUG("Disregarding event ~p", [Message]),
	{next_state, oncall, State}.

%% @doc The various state changes available when an agent is in an outgoing call. <ul>
%%<li>`{released, undefined}'<br />Note this only unsets a previously queued release.</li>
%%<li>`{released, Reason :: string()}'<br />Note this only queues a release for when the call is over.</li>
%%<li>`{wrapup, Call :: #call{}}'</li>
%%<li>`{warmtransfer, Transferto :: any()}'</li>
%%</ul>
-spec(outgoing/3 :: (Event :: {'released', 'undefined'}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'outgoing', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'queued', 'outgoing', #agent{}};
	(Event :: {'wrapup', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'wrapup', #agent{}};
	(Event :: {'warmtransfer', any()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'warmtransfer', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'outgoing', #agent{}}).
outgoing({released, undefined}, _From, State) -> 
	{reply, ok, outgoing, State#agent{queuedrelease=undefined}};
outgoing({released, default}, From, State) ->
	outgoing({released, ?DEFAULT_REL}, From, State);
outgoing({released, {_Id, _Text, Bias} = Reason}, _From, State) when is_integer(Bias), -1 =< Bias, Bias =< 1 -> 
	{reply, queued, outgoing, State#agent{queuedrelease=Reason}};
outgoing({wrapup, #call{id = Callid} = Call}, _From, #agent{statedata = Currentcall} = State) ->
	case Currentcall#call.id of
		Callid -> 
			Newstate = State#agent{state=wrapup, statedata=Call, lastchange = util:now(), oldstate = outgoing},
			gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
			set_cpx_monitor(Newstate, ?WRAPUP_LIMITS, []),
			Client = Call#call.client,
			case proplists:get_value(?WRAPUP_AUTOEND_KEY, Client#client.options) of
				N when is_integer(N) andalso N > 0 ->
					Self = self(),
					erlang:send_after(N * 1000, Self, end_wrapup);
				_ ->
					ok
			end,
			{reply, ok, wrapup, Newstate};
		_Else -> 
			{reply, invalid, outgoing, State}
	end;
outgoing({warmtransfer, Transferto}, _From, State) ->
	StateData = {onhold, State#agent.statedata, calling, Transferto},
	gen_server:cast(State#agent.connection, {change_state, warmtransfer, StateData}),
	Newstate = State#agent{state=warmtransfer, oldstate=outgoing, statedata=StateData, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?WARMTRANSFER_LIMITS, []),
	{reply, ok, warmtransfer, Newstate};
outgoing({agent_transfer, Agent}, _From, #agent{statedata = Call} = State) when is_pid(Agent) ->
	Reply = gen_media:agent_transfer(Call#call.source, Agent, 10000),
	{reply, Reply, outgoing, State};
outgoing({queue_transfer, Queue}, _From, #agent{statedata = Call} = State) ->
	Reply = gen_media:queue(Call#call.source, Queue),
	gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
	Newstate = State#agent{state=wrapup, oldstate=State#agent.state, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?WARMTRANSFER_LIMITS, []),
	{reply, Reply, wrapup, Newstate};
outgoing(get_media, _From, #agent{statedata = Media} = State) when is_record(Media, call) ->
	{reply, {ok, Media}, outgoing, State};
outgoing(_Event, _From, State) -> 
	{reply, invalid, outgoing, State}.

-spec(outgoing/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
outgoing({conn_cast, Request}, #agent{connection = Pid} = State) ->
	case is_pid(Pid) of
		true ->
			gen_server:cast(Pid, Request);
		false ->
			ok
	end,
	{next_state, outgoing, State};
outgoing(register_rejected, #agent{statedata = Media} = State) when Media#call.media_path =:= inband ->
	gen_media:wrapup(Media#call.source),
	{stop, register_rejected, State};
outgoing(register_rejected, State) ->
	{stop, register_rejected, State};
outgoing(_Msg, State) ->
	{next_state, outgoing, State}.

%% @doc The various state changes available when an agent is released. <ul>
%%<li>`{precall, Client :: #client{}}'</li>
%%<li>`idle'</li>
%%<li>`{released, Reason :: string()}'<br />Changes the released reason.</li>
%%<li>`{ringing, Call :: #call{}}'<br />While the system cannot automatically route to a released agent,
%%there is functionality for a supervisor to force it through.</li>
%%</ul>
-spec(released/3 :: (Event :: {'precall', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'precall', #agent{}};
	(Event :: 'idle', From :: pid(), State :: #agent{}) -> {'reply', 'queued', 'idle', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'released', #agent{}};
	(Event :: {'ringing', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'ringing', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'released', #agent{}}).
released({precall, Call}, _From, State) ->
	gen_server:cast(State#agent.connection, {change_state, precall, Call}),
	Newstate = State#agent{state=precall, oldstate=released, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?PRECALL_LIMITS, []),
	{reply, ok, precall, Newstate};
released(idle, _From, State) ->	
	gen_server:cast(dispatch_manager, {now_avail, self()}),
	gen_leader:cast(agent_manager, {now_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, idle}),
	Newstate = State#agent{state=idle, oldstate=released, statedata={}, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?IDLE_LIMITS, []),
	{reply, ok, idle, Newstate};
released({released, default}, From, State) ->
	released({released, ?DEFAULT_REL}, From, State);
released({released, {_Id, _Text, Bias} = Reason}, _From, State) when is_integer(Bias), -1 =< Bias, Bias =< 1 ->
	gen_server:cast(State#agent.connection, {change_state, released, Reason}),
	Newstate = State#agent{statedata=Reason, oldstate=released, lastchange = util:now()},
	log_change(Newstate),
	{reply, ok, released, Newstate};
released({ringing, Call}, _From, State) ->
	gen_server:cast(State#agent.connection, {change_state, ringing, Call}),
	Newstate = State#agent{state=ringing, oldstate=released, statedata=Call, lastchange = util:now(), queuedrelease = State#agent.statedata},
	set_cpx_monitor(Newstate, ?RINGING_LIMITS, []),
	{reply, ok, ringing, Newstate};
released({spy, Target}, {Conn, _Tag}, #agent{connection = Conn} = State) ->
	case self() of
		Target ->
			?INFO("Cannot spy on yourself", []),
			{reply, invalid, released, State};
		_Othertarget ->
			Out = case agent:dump_state(Target) of
				#agent{state = Statename, statedata = Callrec} when Statename =:= oncall; Statename =:= outgoing ->
					Self = self(),
					gen_media:spy(Callrec#call.source, Self);
				_Else ->
					invalid
			end,
			{reply, Out, released, State}
	end;
released(_Event, _From, State) ->
	{reply, invalid, released, State}.

-spec(released/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
released(register_rejected, State) ->
	{stop, register_rejected, State};
released({conn_cast, {mediaload, #call{type = email}} = Request}, #agent{connection = Pid} = State) ->
	%% most likely trying to go spy on an email.
	gen_server:cast(Pid, Request),
	{next_state, released, State};
released(_Msg, State) ->
	{next_state, released, State}.

%% @doc The various calls available when an agent is warmtransfering. <ul>
%%<li>`{released, undefined}'<br />Unqueues a preveiouosly set release request.</li>
%%<li>`{released, Reason :: string()}'<br />Queues a reason after the call is done.</li>
%%<li>`{wrapup, Call :: #call{}}'</li>
%%<li>`{oncall, Call :: #call{}}'<br />If the agent goes back to the orignal call</li>
%%<li>`{outgoing, Call :: #call{}}'</li> TODO outgoing state will go away when callrec supports in/out directions
%%</ul>
-spec(warmtransfer/3 :: (Event :: {'released', undefined}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'warmtransfer', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'queued', 'released', #agent{}};
	(Event :: {'wrapup', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'wrapup', #agent{}};
	(Event :: {'oncall', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'oncall', #agent{}};
	(Event :: {'outgoing', #call{}}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'outgoing', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'warmtransfer', #agent{}}).
warmtransfer({released, undefined}, _From, State) ->
	{reply, ok, warmtransfer, State#agent{queuedrelease=undefined}};
warmtransfer({released, Reason}, _From, State) -> 
	{reply, queued, warmtransfer, State#agent{queuedrelease=Reason}};	
warmtransfer({wrapup, #call{id = Callid} = Call}, _From, #agent{statedata = {onhold, Onhold, calling, _Calling}} = State) -> 
	case Onhold#call.id of
		 Callid -> 
			gen_server:cast(State#agent.connection, {change_state, wrapup, Call}),
			Newstate = State#agent{state=wrapup, oldstate=warmtransfer, statedata=Call, lastchange = util:now()},
			set_cpx_monitor(Newstate, ?WRAPUP_LIMITS, []),
			{reply, ok, wrapup, Newstate};
		_Else -> 
			{reply, invalid, warmtransfer, State}
	end;
warmtransfer({oncall, #call{id = Callid} = Call}, _From, #agent{statedata = {onhold, Onhold, calling, _Calling}} = State) -> 
	case Onhold#call.id of
		 Callid -> 
			gen_server:cast(State#agent.connection, {change_state, oncall, Call}),
			Newstate = State#agent{state=oncall, oldstate=warmtransfer, statedata=Call, lastchange = util:now()},
			set_cpx_monitor(Newstate, ?ONCALL_LIMITS, []),
			{reply, ok, oncall, Newstate};
		_Else -> 
			{reply, invalid, warmtransfer, State}
	end;
warmtransfer({outgoing, Call}, _From, State) ->
	gen_server:cast(State#agent.connection, {change_state, outgoing, Call}),
	Newstate = State#agent{state=outgoing, oldstate=warmtransfer, statedata=Call, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?OUTGOING_LIMITS, []),
	{reply, ok, outgoing, Newstate};
warmtransfer({warmtransfer, TransferTo}, _From, State) ->
	Statedata = setelement(4, State#agent.statedata, TransferTo),
	Newstate = State#agent{statedata = Statedata},
	set_cpx_monitor(Newstate, ?OUTGOING_LIMITS, []),
	{reply, ok, warmtransfer, Newstate};
%warmtransfer({warm_transfer_begin, Number}, _From, #agent{statedata = {onhold, Call, calling, _Call}} = State) ->
	%case gen_media:warm_transfer_begin(Call#call.source, Number, self(), State) of
		%{ok, UUID} ->
			%{reply, ok, warmtransfer, State#agent{statedata={onhold, State#agent.statedata, calling, UUID}}};
		%_ ->
			%{reply, invalid, warmtransfer, State}
	%end;
%warmtransfer(warm_transfer_cancel, _From, #agent{statedata = {onhold, Onhold, calling, _Calling}} = State) ->
	%case gen_media:warm_transfer_cancel(Onhold#call.source) of
		%ok ->
			%NewState = State#agent{state=oncall, oldstate=warmtransfer, statedata=Onhold, lastchange = util:now()},
			%gen_server:cast(State#agent.connection, {change_state, oncall, Onhold}),
			%set_cpx_monitor(NewState, ?ONCALL_LIMITS, []),
			%{reply, ok, oncall, NewState};
		%_ ->
			%{reply, invalid, warmtransfer, State}
	%end;
%warmtransfer(warm_transfer_complete, _From, #agent{statedata = {onhold, Onhold, calling, _Calling}} = State) ->
	%case gen_media:warm_transfer_complete(Onhold#call.source) of
		%ok ->
			%NewState = State#agent{state=wrapup, oldstate=warmtransfer, statedata=Onhold, lastchange = util:now()},
			%gen_server:cast(State#agent.connection, {change_state, wrapup, Onhold}),
			%set_cpx_monitor(NewState, ?WRAPUP_LIMITS, []),
			%{reply, ok, wrapup, NewState};
		%_ ->
			%{reply, invalid, warmtransfer, State}
	%end;
warmtransfer(_Event, _From, State) ->
	{reply, invalid, warmtransfer, State}.

-spec(warmtransfer/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
warmtransfer(register_rejected, #agent{statedata = {onhold, Media, calling, _Target}} = State) ->
	gen_media:wrapup(Media#call.source),
	{stop, register_rejected, State};
warmtransfer({mediapush, Mediapid, Data}, #agent{statedata = {onhold, Media, calling, _}} = State) when Media#call.source =:= Mediapid ->
	case State#agent.connection of
		undefined ->
			{next_state, warmtransfer, State};
		Conn when is_pid(Conn) ->
			?DEBUG("shoving ~p", [Data]),
			gen_server:cast(Conn, {mediapush, Media, Data}),
			{next_state, warmtransfer, State}
	end;
warmtransfer(_Msg, State) ->
	{next_state, warmtransfer, State}.

%% @doc The various state changes available when either the agent or remote has hung-up. <ul>
%%<li>`{released, undefined}'<br />Unqueues a release.</li>
%%<li>`{released, Reason :: string()}'<br />Queues a release the next time the agent tries to go `idle'.</li>
%%<li>`idle'<br />If the agent has a release queued, that state is set instead.</li>
%%</ul>
-spec(wrapup/3 :: (Event :: {'released', undefined}, From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'wrapup', #agent{}};
	(Event :: {'released', release_code()}, From :: pid(), State :: #agent{}) -> {'reply', 'queued', 'wrapup', #agent{}};
	(Event :: 'idle', From :: pid(), State :: #agent{}) -> {'reply', 'ok', 'idle', #agent{}}).
	%(Event :: any(), From :: pid(), State :: #agent{}) -> {'reply', 'invalid', 'wrapup', #agent{}}).
wrapup({released, undefined}, _From, State) ->
	{reply, ok, wrapup, State#agent{queuedrelease=undefined}};
wrapup({released, default}, From, State) ->
	wrapup({released, ?DEFAULT_REL}, From, State);
wrapup({released, {_Id, _Text, Bias} = Reason}, _From, State) when is_integer(Bias), -1 =< Bias, Bias =< 1 ->
	{reply, queued, wrapup, State#agent{queuedrelease=Reason}};
wrapup(idle, _From, #agent{statedata = Call, queuedrelease = undefined} = State) ->
	gen_server:cast(dispatch_manager, {now_avail, self()}),
	gen_leader:cast(agent_manager, {now_avail, State#agent.login}),
	gen_server:cast(State#agent.connection, {change_state, idle}),
	cdr:endwrapup(Call, State#agent.login),
	Newstate = State#agent{state=idle, oldstate=wrapup, statedata={}, lastchange = util:now()},
	set_cpx_monitor(Newstate, ?IDLE_LIMITS, []),
	{reply, ok, idle, Newstate};
wrapup(idle, _From, #agent{statedata=Call} = State) ->
	gen_server:cast(State#agent.connection, {change_state, released, State#agent.queuedrelease}),
	cdr:endwrapup(Call, State#agent.login),
	Newstate = State#agent{state=released, oldstate=wrapup, statedata=State#agent.queuedrelease, queuedrelease=undefined, lastchange = util:now()},
	{Id, Reason, Bias} = State#agent.queuedrelease,
	set_cpx_monitor(Newstate, ?RELEASED_LIMITS(Bias), [{reason, Reason}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, Newstate};
wrapup(Event, From, State) ->
	?WARNING("Invalid event '~p' from ~p while in wrapup.", [Event, From]),
	{reply, invalid, wrapup, State}.

-spec(wrapup/2 :: (Msg :: any(), State :: #agent{}) -> {'stop', any(), #agent{}} | {'next_state', statename(), #agent{}}).
wrapup(register_rejected, State) ->
	{stop, register_rejected, State};
wrapup(_Msg, State) ->
	{next_state, wrapup, State}.

% generic handlers independant of state
%% @private
%-spec(handle_event/3 :: (Event :: 'stop', StateName :: statename(), State :: #agent{}) -> {'stop','normal', #agent{}}).
	%(Event :: any(), StateName :: atom(), State :: #agent{}) -> {'next_state', atom(), #agent{}}).
handle_event({blab, Text}, Statename, #agent{connection = Conpid} = State) when is_pid(Conpid) ->
	?DEBUG("sending blab ~p", [Text]),
	gen_server:cast(Conpid, {blab, Text}),
	{next_state, Statename, State};
handle_event(stop, _StateName, State) -> 
	{stop, normal, State};
handle_event(_Event, StateName, State) ->
	{next_state, StateName, State}.

%% @private
%-spec(handle_sync_event/4 :: (Event :: any(), From :: pid(), StateName :: statename(), State :: #agent{}) -> {'reply', any(), atom(), #agent{}}).
handle_sync_event(query_state, _From, StateName, State) -> 
	{reply, {ok, StateName}, StateName, State};
handle_sync_event(dump_state, _From, StateName, State) ->
	{reply, State, StateName, State};
handle_sync_event({set_connection, Pid}, _From, StateName, #agent{connection = undefined} = State) ->
	link(Pid),
	gen_server:cast(Pid, {change_state, State#agent.state, State#agent.statedata}),
	case erlang:function_exported(cpx_supervisor, get_value, 1) of
		true ->
			case cpx_supervisor:get_value(motd) of
				{ok, Motd} ->
					gen_server:cast(Pid, {blab, Motd});
				_ ->
					ok
			end;
		false ->
			ok
	end,
	{reply, ok, StateName, State#agent{connection=Pid}};
handle_sync_event({set_connection, _Pid}, _From, StateName, State) ->
	?WARNING("An attempt to set connection to ~w when there is already a connection ~w", [_Pid, State#agent.connection]),
	{reply, error, StateName, State};
handle_sync_event({set_endpoint, {Endpointtype, Endpointdata}}, _From, StateName, State) ->
	{reply, ok, StateName, State#agent{endpointtype = Endpointtype, endpointdata = Endpointdata}};
handle_sync_event({url_pop, URL, Name}, _From, StateName, #agent{connection=Connection} = State) when is_pid(Connection) ->
	gen_server:cast(Connection, {url_pop, URL, Name}),
	{reply, ok, StateName, State};
handle_sync_event({add_skills, Skills}, _From, StateName, State) ->
	NewSkills = util:merge_skill_lists(expand_magic_skills(State, Skills), State#agent.skills, ['_queue', '_brand']),
	agent_manager:update_skill_list(State#agent.login, NewSkills),
	{reply, ok, StateName, State#agent{skills = NewSkills}};
handle_sync_event({remove_skills, Skills}, _From, StateName, State) ->
	NewSkills = util:subtract_skill_lists(State#agent.skills, expand_magic_skills(State, Skills)),
	agent_manager:update_skill_list(State#agent.login, NewSkills),
	{reply, ok, StateName, State#agent{skills = NewSkills}};
handle_sync_event({change_profile, Profile}, _From, StateName, State) ->
	OldProfile = State#agent.profile,
	OldSkills = case agent_auth:get_profile(OldProfile) of
		#agent_profile{skills = Skills} ->
			Skills;
		_ ->
			[]
	end,
	case agent_auth:get_profile(Profile) of
		#agent_profile{name = Profile, skills = Skills2} ->
			NewAgentSkills = util:subtract_skill_lists(State#agent.skills, expand_magic_skills(State, OldSkills)),
			NewAgentSkills2 = util:merge_skill_lists(NewAgentSkills, expand_magic_skills(State#agent{profile = Profile}, Skills2), ['_queue', '_brand']),
			Newstate = State#agent{skills = NewAgentSkills2, profile = Profile},
			Deatils = [{profile, Newstate#agent.profile}, {state, Newstate#agent.state}, {statedata, Newstate#agent.statedata}, {login, Newstate#agent.login}, {lastchange, {timestamp, Newstate#agent.lastchange}}],
			{S, {T1, T2, T3, {time, _Now}}} = case StateName of
				idle ->
					?IDLE_LIMITS;
				released ->
					[Rel1, _] = ?RELEASED_LIMITS(0),
					Rel1;
				precall -> 
					?PRECALL_LIMITS;
				outgoing -> 
					?OUTGOING_LIMITS;
				oncall ->
					?ONCALL_LIMITS;
				wrapup -> 
					?WRAPUP_LIMITS;
				ringing -> 
					?RINGING_LIMITS;
				warmtransfer ->
					?WARMTRANSFER_LIMITS
			end,
			gen_server:cast(State#agent.connection, {change_profile, Profile}),
			State#agent.log_pid ! {change_profile, Profile, StateName},
			Time = Newstate#agent.lastchange,
			Fixedhp = case StateName of
				released ->
					{_, _, Bias} = State#agent.statedata,
					[_, Biashp] = ?RELEASED_LIMITS(Bias),
					[{S, {T1, T2, T3, {time, Time}}}, Biashp];
				_ ->
					[{S, {T1, T2, T3, {time, Time}}}]
			end,
			cpx_monitor:set({agent, State#agent.id}, Fixedhp, Deatils),
			{reply, ok, StateName, Newstate};
		_ ->
			{reply, {error, unknown_profile}, StateName, State}
	end;
handle_sync_event(_Event, _From, StateName, State) ->
	{reply, ok, StateName, State}.

%% @private
%-spec(handle_info/3 :: (Event :: any(), StateName :: statename(), State :: #agent{}) -> {'stop', 'normal', #agent{}} | {'stop', 'shutdown', #agent{}} | {'stop', 'timeout', #agent{}} | {'next_state', statename(), #agent{}}).
handle_info({'EXIT', From, Reason}, Statename, #agent{log_pid = From} = State) ->
	?INFO("Log pid ~w died due to ~p", [From, Reason]),
	Nodes = case proplists:get_value(nodes, State#agent.start_opts) of
		undefined -> [node()];
		Else -> Else
	end,
	Pid = spawn_link(agent, log_loop, [State#agent.id, State#agent.login, Nodes, State#agent.profile]),
	{next_state, Statename, State#agent{log_pid = Pid}};
handle_info({'EXIT', From, Reason}, oncall, #agent{connection = From, statedata = Call} = State) ->
	?WARNING("agent connection died while ~w with ~w media", [oncall, Call#call.media_path]),
	case Call#call.media_path of
		inband ->
			Stopwhy = case Reason of
				normal ->
					normal;
				shutdown ->
					shutdown;
				Other ->
					{error, conn_exit, Other}
			end,
			gen_media:wrapup(Call#call.source),
			cdr:endwrapup(Call, State#agent.login),
			{stop, Stopwhy, State#agent{connection = undefined}};
		outband ->
			% to avoid sudden dropped calls, hang around.
			{next_state, oncall, State#agent{connection = undefined}}
	end;
handle_info({'EXIT', From, Reason}, outgoing, #agent{connection = From, statedata = Call} = State) ->
	?WARNING("agent connection died while ~w with ~w media", [outgoing, Call#call.media_path]),
	case Call#call.media_path of
		inband ->
			Stopwhy = case Reason of
				normal ->
					normal;
				shutdown ->
					shutdown;
				Other ->
					{error, conn_exit, Other}
			end,
			gen_media:wrapup(Call#call.source),
			cdr:endwrapup(Call, State#agent.login),
			{stop, Stopwhy, State#agent{connection = undefined}};
		outband ->
			{next_state, outgoing, State#agent{connection = undefined}}
	end;
handle_info({'EXIT', From, Reason}, warmtransfer, #agent{connection = From, statedata = Tuple} = State) ->
	{onhold, Call, calling, _Whoever} = Tuple,
	?WARNING("agent connection died while ~w with ~w media", [warmtransfer, Call#call.media_path]),
	case Call#call.media_path of
		inband ->
			Stopwhy = case Reason of
				normal ->
					normal;
				shutdown ->
					shutdown;
				Other ->
					{error, conn_exit, Other}
			end,
			gen_media:wrapup(Call#call.source),
			cdr:endwrapup(Call, State#agent.login),
			{stop, Stopwhy, State#agent{connection = undefined}};
		outband ->
			{next_state, warmtransfer, State#agent{connection = undefined}}
	end;
handle_info({'EXIT', From, Reason}, wrapup, #agent{connection = From} = State) ->
	?WARNING("agent connection died while ~w with ~p media", [wrapup, "doesn't matter"]),
	cdr:endwrapup(State#agent.statedata, State#agent.login),
	Stopwhy = case Reason of
		normal ->
			normal;
		shutdown ->
			shutdown;
		Other ->
			{error, conn_exit, Other}
	end,
	{stop, Stopwhy, State};
handle_info({'EXIT', From, Reason}, StateName, #agent{connection = From} = State) ->
	?WARNING("agent connection died while ~w with ~p media", [StateName, "doesn't matter"]),
	Stopwhy = case Reason of
		normal ->
			normal;
		shutdown ->
			shutdown;
		Other ->
			{error, conn_exit, Other}
	end,
	{stop, Stopwhy, State};
handle_info({'EXIT', From, Reason}, StateName, State) ->
	?INFO("Got exit message from ~p with reason ~p", [From, Reason]),
	case whereis(agent_manager) of
		undefined ->
			agent_manager_exit(Reason, StateName, State);
		From ->
			agent_manager_exit(Reason, StateName, State);
		_Else ->
			?INFO("unknown exit from ~p", [From]),
			{next_state, StateName, State}
	end;
handle_info(end_wrapup, wrapup, State) ->
	{reply, ok, Nextstate, Newstate} = wrapup(idle, self(), State),
	{next_state, Nextstate, Newstate};
handle_info(_Info, StateName, State) ->
	{next_state, StateName, State}.

%% @private
-spec(agent_manager_exit/3 :: (Reason :: any(), StateName :: statename(), State :: #agent{}) -> {'stop', 'normal', #agent{}} | {'stop', 'shutdown', #agent{}} | {'stop', 'timeout', #agent{}} | {'next_state', statename(), #agent{}}).
agent_manager_exit(Reason, StateName, State) ->
	case Reason of
		normal ->
			?INFO("Agent manager exited normally", []),
			{stop, normal, State};
		shutdown ->
			?INFO("Agent manager shutdown", []),
			{stop, shutdown, State};
		_Else ->
			?INFO("Agent manager exited abnormally with reason ~p", [Reason]),
			wait_for_agent_manager(5, StateName, State)
	end.

-spec(wait_for_agent_manager/3 :: (Count :: non_neg_integer(), StateName :: statename(), State :: #agent{}) -> {'stop', 'timeout', #agent{}} | {'next_state', statename(), #agent{}}).
wait_for_agent_manager(0, _StateName, State) ->
	?WARNING("Timed out waiting for agent manager respawn", []),
	{stop, timeout, State};
wait_for_agent_manager(Count, StateName, State) ->
	case whereis(agent_manager) of
		undefined ->
			timer:sleep(1000),
			wait_for_agent_manager(Count - 1, StateName, State);
		Else when is_pid(Else) ->
			?INFO("Agent manager respawned as ~p", [Else]),
			% this will throw an error if the agent is already registered as
			% a different pid and that error will crash this process
			?INFO("Notifying new agent manager of agent ~p at ~p", [State#agent.login, self()]),
			agent_manager:notify(State#agent.login, State#agent.id, self()),
			{next_state, StateName, State}
	end.

% obviousness below.
%% @private
%-spec(terminate/3 :: (Reason :: any(), StateName :: statename(), State :: #agent{}) -> 'ok').
terminate(Reason, StateName, State) ->
	?NOTICE("Agent terminating:  ~p, State:  ~p", [Reason, StateName]),
%	case State#agent.log_pid of
%		Pid when is_pid(Pid) ->
%			Pid ! {State#agent.login, logout};
%		undefined ->
%			ok
%	end,
	cpx_monitor:drop({agent, State#agent.id}),
	ok.

%% @private
%-spec(code_change/4 :: (OldVsn :: string(), StateName :: statename(), State :: #agent{}, Extra :: any()) -> {'ok', statename(), #agent{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
	{ok, StateName, State}.

-spec(format_status/2 :: (Cause :: atom(), Data :: [any()]) -> any()).
format_status(normal, [PDict, State]) ->
	[{data, [{"State", format_status(terminate, [PDict, State])}]}];
format_status(terminate, [_PDict, State]) ->
	% prevent client data from being dumped
	NewState = case State#agent.statedata of
		#call{client = Client} = Call when is_record(Call#call.client, client) ->
			Client = Call#call.client,
			State#agent{statedata = Call#call{client = Client#client{options = []}}};
		{onhold, #call{client = Client} = Call, calling, ID} when is_record(Client, client) ->
			State#agent{statedata = {onhold, Call#call{client = Client#client{options = []}}, calling, ID}};
		_ ->
			State
	end,
	NewState#agent{password = redacted}.


%% =====
%% Internal functions
%% =====

set_cpx_monitor(State, Hp, Otherdeatils) when is_list(Hp)->
	log_change(State),
	Deatils = lists:append([{profile, State#agent.profile}, {state, State#agent.state}, {statedata, State#agent.statedata}, {login, State#agent.login}, {lastchange, {timestamp, State#agent.lastchange}}], Otherdeatils),
	cpx_monitor:set({agent, State#agent.id}, Hp, Deatils);
set_cpx_monitor(State, Hp, Dets) ->
	set_cpx_monitor(State, [Hp], Dets).

log_change(#agent{log_pid = undefined}) ->
	ok;
log_change(#agent{log_pid = Pid} = State) when is_pid(Pid) ->
	Pid ! {State#agent.login, State#agent.state, State#agent.oldstate, State#agent.statedata},
	ok.

-spec(log_loop/4 :: (Id :: string(), Agentname :: string(), Nodes :: [atom()], Profile :: string() | {string(), string()}) -> 'ok').
log_loop(Id, Agentname, Nodes, ProfileTup) ->
	process_flag(trap_exit, true),
	Profile = case ProfileTup of
		{Currentp, _Queuedp} ->
			Currentp;
		_ ->
			ProfileTup
	end,
	receive
		{Agentname, login, State, Statedata} ->
			F = fun() ->
				Now = util:now(),
				mnesia:dirty_write(#agent_state{id = Id, agent = Agentname, oldstate = login, state=State,
						start = Now, ended = Now, profile= Profile, nodes = Nodes}),
				mnesia:dirty_write(#agent_state{agent = Agentname, oldstate = State, statedata = Statedata, start = Now, nodes = Nodes}),
				gen_cdr_dumper:update_notify(agent_state),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent state login:  ~p", [Res]),
			agent:log_loop(Id, Agentname, Nodes, ProfileTup);
		{'EXIT', _Apid, _Reason} ->
			F = fun() ->
				Now = util:now(),
				QH = qlc:q([Rec || Rec <- mnesia:table(agent_state), Rec#agent_state.id =:= Id, Rec#agent_state.ended =:= undefined]),
				Recs = qlc:e(QH),
				?DEBUG("Recs to loop through:  ~p", [Recs]),
				lists:foreach(
					fun(Untermed) ->
						mnesia:delete_object(Untermed), 
						mnesia:write(Untermed#agent_state{ended = Now, timestamp = Now, state = logout})
					end,
					Recs
				),
				gen_cdr_dumper:update_notify(agent_state),
				%Stateage = fun(#agent_state{start = A}, #agent_state{start = B}) ->
					%B =< A
				%end,
				%[#agent_state{state = Oldstate} | _] = lists:sort(Stateage, Recs),
				%Newrec = #agent_state{id = Id, agent = Agentname, state = logout, oldstate = State, statedata = "job done", start = Now, ended = Now, timestamp = Now, nodes = Nodes},
				%mnesia:write(Newrec),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent state change log:  ~p", [Res]),
			ok;
		{change_profile, Newprofile, State} when State == idle; State == released ->
			agent:log_loop(Id, Agentname, Nodes, Newprofile);
		{change_profile, Newprofile, _State} ->
			case ProfileTup of
				{Current, _Queued} ->
					agent:log_loop(Id, Agentname, Nodes, {Current, Newprofile});
				Current ->
					agent:log_loop(Id, Agentname, Nodes, {Current, Newprofile})
			end;
		{Agentname, State, _OldState, Statedata} ->
			F = fun() ->
				Now = util:now(),
				QH = qlc:q([Rec || Rec <- mnesia:table(agent_state), Rec#agent_state.id =:= Id, Rec#agent_state.ended =:= undefined]),
				Recs = qlc:e(QH),
				lists:foreach(
					fun(Untermed) -> 
						mnesia:delete_object(Untermed), 
						mnesia:write(Untermed#agent_state{ended = Now, timestamp = Now, state = State})
					end,
					Recs
				),
				gen_cdr_dumper:update_notify(agent_state),
				Newrec = #agent_state{id = Id, agent = Agentname, oldstate = State, statedata = Statedata, profile = Profile, start = Now, nodes = Nodes},
				mnesia:write(Newrec),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent state change log:  ~p", [Res]),
			case {State, ProfileTup} of
				{State, {Profile, Queued}} when State == wrapup; State == idle; State == released ->
					agent:log_loop(Id, Agentname, Nodes, Queued);
				_ ->
					agent:log_loop(Id, Agentname, Nodes, ProfileTup)
			end
	end.
	
-ifdef(TEST).

start_arbitrary_state_test() ->
	{ok, Pid} = start(#agent{login = "testagent", state = idle}),
	?assertEqual({ok, idle}, query_state(Pid)),
	agent:stop(Pid).		
	
ring_oncall_mismatch_test() ->
	{_, Pid} = start(#agent{login="testagent"}),
	Goodcall = #call{id="Goodcall", source=self()},
	Badcall = #call{id="Badcall", source=self()},
	?assertMatch(ok, set_state(Pid, idle)),
	?assertMatch(ok, set_state(Pid, ringing, Goodcall)),
	?assertMatch(invalid, set_state(Pid, oncall, Badcall)).

expand_magic_skills_test_() ->
	Agent = #agent{login = "testagent", profile = "testprofile", skills = ['_agent', '_node', '_profile', english, {'_brand', "testbrand"}]},
	Newskills = expand_magic_skills(Agent, Agent#agent.skills),
	[?_assert(lists:member({'_agent', "testagent"}, Newskills)),
	?_assert(lists:member({'_node', node()}, Newskills)),
	?_assert(lists:member(english, Newskills)),
	?_assert(lists:member({'_profile', "testprofile"}, Newskills)),
	?_assert(lists:member({'_brand', "testbrand"}, Newskills))].
	
from_idle_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		?CONSOLE("Test args:  ~p", [[Agent, Dmock, Monmock, Connmock, Logpid, Assertmocks]]),
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks} = _Testargs) ->
		{"to precall",
		fun() ->
			Client = #client{label = "testclient"},
			Aself = self(),
			gen_server_mock:expect_cast(Dmock, fun({end_avail, Self}, _State) ->
				Self = Aself,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{precall, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, precall, Inclient}, _State) -> 
				Inclient = Client,
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", precall, idle, _Client}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			?assertMatch({reply, ok, precall, _State}, idle({precall, Client}, {"ref", "pid"}, Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, AMmock, _Dmock, Monmock, Connmock, Assertmocks} = _Testargs) ->
		{"to ringing",
		fun() ->
			Self = self(),
			Call = #call{
				id = "testcall",
				source = Self
			},
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{ringing, _Limits}] = Health,
				?assertEqual(node(), Node),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, ringing, Incall}, _State) -> 
				Call = Incall,
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", ringing, idle, _Call}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			?assertMatch({reply, ok, ringing, _State}, idle({ringing, Call}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with invalid format",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({released, "not a valid data"}, "from", Agent)), Assertmocks()
		end}
	end,
	fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released with default",
		fun() ->
			Self = self(),
			gen_server_mock:expect_cast(Dmock, fun({end_avail, Apid}, _State) ->
				Self = Apid,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, _}] = Health,
				?assertEqual(node(), Node),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, idle, ?DEFAULT_REL}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			?assertMatch({reply, ok, released, _State}, idle({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released",
		fun() ->
			Self = self(),
			gen_server_mock:expect_cast(Dmock, fun({end_avail, Apid}, _State) ->
				Self = Apid,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, _}] = Health,
				?assertEqual(node(), Node),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, {"id", "just 'cause", 0}}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, idle, {"id", "just 'cause", 0}}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			?assertMatch({reply, ok, released, _State}, idle({released, {"id", "just 'cause", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing with invalid call",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({ringing, "not a call rec"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({warmtransfer, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			?assertMatch({reply, invalid, idle, _State}, idle({wrapup, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

from_ringing_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		gen_leader_mock:expect_leader_cast(Monmock, fun({set, _}, _, _) -> ok end),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Mpid} = dummy_media:start([{id, "testcall"}, {queues, none}]),
		{ok, Logpid} = gen_server_mock:new(),
		ProtoCallrec = gen_media:get_call(Mpid),
		exit(Mpid, kill),
		{ok, Mediamock} = gen_server_mock:new(),
		Callrec = ProtoCallrec#call{source = Mediamock},
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, statedata = Callrec, state = ringing, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({#agent{statedata = Callrec}, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_server_mock:stop(Callrec#call.source),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			Aself = self(),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{idle, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, idle}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", idle, ringing, {}}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({now_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			%gen_leader_mock:expect_leader_cast(AMmock, fun(_, _State, _Elect) -> ok end),
%			gen_server_mock:expect_cast(Dmock, fun({now_avail, Self}, _State) ->
%				Self = Aself,
%				ok
%			end),
			?assertMatch({reply, ok, idle, _State}, ringing(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({ringing, "doens't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to oncall with inband media path",
		fun() ->
			Callrec = Agent#agent.statedata, 
			gen_server_mock:expect_cast(Dmock, fun({end_avail, _Apid}, _State) -> ok end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{oncall, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, oncall, Inrec}, _State) ->
				Inrec = Agent#agent.statedata,
				ok
			end),
			gen_server_mock:expect_call(Callrec#call.source, fun(_Message, _From, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", oncall, ringing, _Callrec}, _State) -> ok end),
			?assertMatch({reply, ok, oncall, _State}, ringing(oncall, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall with failing inband media",
		fun() ->
			Callrec = Agent#agent.statedata,
			gen_server_mock:expect_call(Callrec#call.source, fun(_Message, _From, State) ->
				{ok, invalid, State}
			end),
			?assertMatch({reply, invalid, ringing, _State}, ringing(oncall, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Oldagent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to oncall with outband media path",
		fun() ->
			Oldcall = Oldagent#agent.statedata, 
			Callrec = Oldcall#call{ring_path = outband, media_path = outband},
			Agent = Oldagent#agent{statedata = Callrec},
			gen_server_mock:expect_cast(Dmock, fun({end_avail, _Apid}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, _Nom}, _State, _Elec) -> ok end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, oncall, Inrec}, _State) ->
				Inrec = Agent#agent.statedata,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{oncall, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", oncall, ringing, _Callrec}, _State) -> ok end),
			?assertMatch({reply, ok, oncall, _State}, ringing({oncall, Callrec}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall with call id mismatch",
		fun() ->
			Oldcall = Agent#agent.statedata,
			Callrec = Oldcall#call{id = "invalid"},
			?assertMatch({reply, invalid, ringing, _State}, ringing({oncall, Callrec}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _, _, _, _, _}) ->
		{"to released with bad format",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({released, "not valid"}, "from", Agent))
		end}
	end,
	fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released default",
		fun() ->
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, 60}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Dmock, fun({end_avail, _Apid}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, _Nom}, _State, _Elec) -> ok end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			Callrec = Agent#agent.statedata,
			Self = self(),
			gen_server_mock:expect_info(Callrec#call.source, fun({'$gen_media_stop_ring', Inpid}, _State) ->
				Inpid = Self,
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, ringing, ?DEFAULT_REL}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, ringing({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released",
		fun() ->
			gen_server_mock:expect_cast(Dmock, fun({end_avail, _Apid}, _State) -> ok end),
			gen_leader_mock:expect_cast(AMmock, fun({end_avail, _Nom}, _State) -> ok end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, 50}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, {"id", "res_reason", 0}}, _State) ->
				ok
			end),
			Callrec = Agent#agent.statedata,
			Self = self(),
			gen_server_mock:expect_info(Callrec#call.source, fun({'$gen_media_stop_ring', Inpid}, _State) ->
				Inpid = Self,
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, ringing, {"id", "res_reason", 0}}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, ringing({released, {"id", "res_reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({warmtransfer, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			?assertMatch({reply, invalid, ringing, _State}, ringing({wrapup, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

from_precall_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient", id = "testclient"},
		Call = #call{id = "testcall", client = Client, source = spawn(fun() -> ok end)},
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = precall, statedata = Call, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_leader_mock:assert_expectations(AMmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			Apid = self(),
			gen_server_mock:expect_cast(Dmock, fun({now_avail, Pid}, _State) ->
				Apid = Pid,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{idle, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, idle}, _State) ->
				ok
			end),
			gen_leader_mock:expect_cast(AMmock, fun({now_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", idle, precall, {}}, _State) -> ok end),
			?assertMatch({reply, ok, idle, _State}, precall(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({ringing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, outgoing, _Data}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{outgoing, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", outgoing, precall, _}, _State) -> ok end),
			?assertMatch({reply, ok, outgoing, _State}, precall({outgoing, #call{id = "testcall", source = spawn(fun() -> ok end)} }, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with bad info",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({released, "reason"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released with default",
		fun() ->
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				Node = node(),
				[{released, _Limits}, {bias, _}] = Health,
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, precall, ?DEFAULT_REL}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, precall({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to released",
		fun() ->
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				Node = node(),
				[{released, _Limits}, {bias, _}] = Health,
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, {"id", "reason", 0}}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, precall, {"id", "reason", 0}}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, precall({released, {"id", "reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({warmtransfer, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			?assertMatch({reply, invalid, precall, _State}, precall({wrapup, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

from_oncall_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient"},
		{ok, Mediapid} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		Callrec = #call{
			id = "testcall",
			source = Mediapid,
			client = Client
		},
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = oncall, statedata = Callrec, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall({ringing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released when no release queued with default reason",
		fun() ->
			?assertMatch({reply, queued, oncall, _State}, oncall({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released when no release queued with invalid reason",
		fun() ->
			?assertMatch({reply, invalid, oncall, _State}, oncall({released, "goober"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released when no release queued with valid reason",
		fun() ->
			?assertMatch({reply, queued, oncall, _State}, oncall({released, {"id", "goober", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Oldagent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released when a release is queued",
		fun() ->
			Agent = Oldagent#agent{queuedrelease = "oldreason"},
			?assertMatch({reply, queued, oncall, _State}, oncall({released, {"id", "new reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Oldagent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released (default) when a release is queued",
		fun() ->
			Agent = Oldagent#agent{queuedrelease = {"oid", "oldreason", 0}},
			?assertMatch({reply, queued, oncall, _State}, oncall({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Oldagent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released (invalid) when a release is queued",
		fun() ->
			Agent = Oldagent#agent{queuedrelease = {"oid", "oldreason", 0}},
			?assertMatch({reply, invalid, oncall, _State}, oncall({released, "new reason"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Oldagent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released undefined",
		fun() ->
			Agent = Oldagent#agent{queuedrelease = {"oid", "oldreason", 0}},
			?assertMatch({reply, ok, oncall, _State}, oncall({released, undefined}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			%Callrec = Agent#agent.statedata,
			gen_server_mock:expect_cast(Connmock, fun({change_state, warmtransfer, {onhold, _Callrec, calling, "transferto"}}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{warmtransfer, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, 
				fun({"testagent", warmtransfer, oncall, {onhold, Call, calling, "transferto"}}, _State) -> 
					Call = Agent#agent.statedata,
					ok 
				end),
			?assertMatch({reply, ok, warmtransfer, _State}, oncall({warmtransfer, "transferto"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, Incall}, _State) ->
				Incall = Agent#agent.statedata,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, oncall, Incall}, _State) -> Incall = Agent#agent.statedata, ok end),
			?assertMatch({reply, ok, wrapup, _State}, oncall({wrapup, Agent#agent.statedata}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({BaseAgent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup with a hard end",
		fun() ->
			Basecall = BaseAgent#agent.statedata,
			Client = #client{label = "testclient", options = [{?WRAPUP_AUTOEND_KEY, 1}]},
			Callrec = Basecall#call{client = Client},
			Agent = BaseAgent#agent{statedata = Callrec},
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, Incall}, _State) ->
				Incall = Agent#agent.statedata,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, oncall, Incall}, _State) -> Incall = Agent#agent.statedata, ok end),
			?assertMatch({reply, ok, wrapup, _State}, oncall({wrapup, Agent#agent.statedata}, "from", Agent)),
			Gotend = receive
				end_wrapup ->
					ok
			after 1500 ->
				error
			end,
			?assertEqual(ok, Gotend),
			Assertmocks()
		end}
	end,
	fun({BaseAgent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup with hard end and inband media",
		fun() ->
			Basecall = BaseAgent#agent.statedata,
			Client = #client{label = "testclient", options = [{?WRAPUP_AUTOEND_KEY, 1}]},
			Callrec = Basecall#call{client = Client, media_path = inband},
			Agent = BaseAgent#agent{statedata = Callrec},
			gen_server_mock:expect_call(Callrec#call.source, fun('$gen_media_wrapup', _From, _State) -> ok end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, Incall}, _State) ->
				Incall = Agent#agent.statedata,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, oncall, Incall}, _State) -> Incall = Agent#agent.statedata, ok end),
			?assertMatch({reply, ok, wrapup, _State}, oncall(wrapup, "from", Agent)),
			Gotend = receive
				end_wrapup ->
					ok
			after 1500 ->
				error
			end,
			?assertEqual(ok, Gotend),
			Assertmocks()
		end}
	end]}.

from_outgoing_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient"},
		{ok, Mediapid} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		Callrec = #call{
			id = "testcall",
			source = Mediapid,
			client = Client
		},
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = oncall, statedata = Callrec, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({ringing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to unqueuing a release",
		fun() ->
			?assertMatch({reply, ok, outgoing, _State}, outgoing({released, undefined}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to queue a default release",
		fun() ->
			?assertMatch({reply, queued, outgoing, _State}, outgoing({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to queue a valid release",
		fun() ->
			?assertMatch({reply, queued, outgoing, _State}, outgoing({released, {"id", "reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to queue an invalid release",
		fun() ->
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({released, "bad bad juju"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to requeue a release",
		fun() ->
			?assertMatch({reply, queued, outgoing, _State}, outgoing({released, default}, "from", Agent)),
			?assertMatch({reply, queued, outgoing, _State}, outgoing({released, {"id", "new reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, warmtransfer, {onhold, #call{id = "testcall"}, calling, "transferto"}}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{warmtransfer, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, 
				fun({"testagent", warmtransfer, outgoing, {onhold, Call, calling, "transferto"}}, _State) ->
					Call = Agent#agent.statedata,
					ok
				end),
			?assertMatch({reply, ok, warmtransfer, _State}, outgoing({warmtransfer, "transferto"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, _Calldata}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, outgoing, Call}, _State) ->
				Call = Agent#agent.statedata, 
				ok
			end),
			?assertMatch({reply, ok, wrapup, _State}, outgoing({wrapup, Agent#agent.statedata}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup with call id mismatch",
		fun() ->
			Oldrec = Agent#agent.statedata,
			Invalidrec = Oldrec#call{id = "bad bad leroy brown"},
			?assertMatch({reply, invalid, outgoing, _State}, outgoing({wrapup, Invalidrec}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({BaseAgent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup with a hard end",
		fun() ->
			Basecall = BaseAgent#agent.statedata,
			Client = #client{label = "testclient", options = [{?WRAPUP_AUTOEND_KEY, 1}]},
			Callrec = Basecall#call{client = Client},
			Agent = BaseAgent#agent{statedata = Callrec},
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, _Calldata}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, outgoing, Call}, _State) ->
				Call = Agent#agent.statedata, 
				ok
			end),
			?assertMatch({reply, ok, wrapup, _State}, outgoing({wrapup, Agent#agent.statedata}, "from", Agent)),
			Gotend = receive
				end_wrapup ->
					ok
			after 1500 ->
				error
			end,
			?assertEqual(ok, Gotend),
			Assertmocks()
		end}
	end]}.

from_released_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = released, statedata = "testrelease", log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, idle}, _State) ->
				ok
			end),
			Self = self(),
			gen_server_mock:expect_cast(Dmock, fun({now_avail, Apid}, _State) ->
				Self = Apid,
				ok
			end),
			gen_leader_mock:expect_cast(AMmock, fun({now_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{idle, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", idle, released, {}}, _State) -> ok end),
			?assertMatch({reply, ok, idle, _State}, released(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, ringing, "callrec"}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{ringing, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", ringing, released, "callrec"}, _State) -> ok end),
			?assertMatch({reply, ok, ringing, _State}, released({ringing, "callrec"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, precall, "client"}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{precall, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", precall, released, "client"}, _State) -> ok end),
			?assertMatch({reply, ok, precall, _State}, released({precall, "client"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, released, _State}, released({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, released, _State}, released({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, Connmock, Assertmocks}) ->
		{"to released default",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, released, ?DEFAULT_REL}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, released({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, Connmock, Assertmocks}) ->
		{"to released valid",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, {"id", "reason", 0}}, _State) ->
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, released, {"id", "reason", 0}}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, released({released, {"id", "reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released invalid",
		fun() ->
			?assertMatch({reply, invalid, released, _State}, released({released, "not gonna work"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			?assertMatch({reply, invalid, released, _State}, released({warmtransfer, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			?assertMatch({reply, invalid, released, _State}, released({wrapup, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

from_warmtransfer_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient"},
		{ok, Mediapid} = gen_server_mock:new(),
		Callrec = #call{
			id = "testcall",
			source = Mediapid,
			client = Client
		},
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = warmtransfer, statedata = {onhold, Callrec, calling, "testtarget"}, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			?assertMatch({reply, invalid, warmtransfer, _State}, warmtransfer(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, warmtransfer, _State}, warmtransfer({ringing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, warmtransfer, _State}, warmtransfer({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			{onhold, Callrec, calling, _Whoever} = Agent#agent.statedata,
			gen_server_mock:expect_cast(Connmock, fun({change_state, oncall, Inrec}, _State) ->
				Callrec = Inrec,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{oncall, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", oncall, warmtransfer, _Callrec}, _State) -> ok end),
			?assertMatch({reply, ok, oncall, _State}, warmtransfer({oncall, Callrec}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall with id mismatch",
		fun() ->
			Badcall = #call{id = "hagurk", source= self()},
			?assertMatch({reply, invalid, warmtransfer, _State}, warmtransfer({oncall, Badcall}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			gen_server_mock:expect_cast(Connmock, fun({change_state, outgoing, _Inrec}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock,fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{outgoing, _Limits}] = Health, 
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", outgoing, warmtransfer, Callrec}, _State) ->
				Callrec = element(2, Agent#agent.statedata),
				ok
			end),
			?assertMatch({reply, ok, outgoing, _State}, warmtransfer({outgoing, element(2, Agent#agent.statedata)}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			{onhold, Callrec, calling, _Whoever} = Agent#agent.statedata,
			gen_server_mock:expect_cast(Connmock, fun({change_state, wrapup, Inrec}, _State) ->
				Callrec = Inrec,
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{wrapup, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", wrapup, warmtransfer, _Callrec}, _State) -> ok end),
			?assertMatch({reply, ok, wrapup, _State}, warmtransfer({wrapup, Callrec}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall with id mismatch",
		fun() ->
			Badcall = #call{id = "hagurk", source= self()},
			?assertMatch({reply, invalid, warmtransfer, _State}, warmtransfer({wrapup, Badcall}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

from_wrapup_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient"},
		{ok, Mediapid} = gen_server_mock:new(),
		Callrec = #call{
			id = "testcall",
			source = Mediapid,
			client = Client
		},
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = warmtransfer, statedata = Callrec, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}
	end,
	fun({_Agent, AMmock, Dmock, Monmock, Connmock, _Assertmocks}) ->
		gen_server_mock:stop(Dmock),
		gen_leader_mock:stop(Monmock),
		gen_server_mock:stop(Connmock),
		gen_leader_mock:stop(AMmock),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, AMmock, Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to idle",
		fun() ->
			Self = self(),
			gen_server_mock:expect_cast(Dmock, fun({now_avail, Apid}, _State) ->
				Self = Apid,
				ok
			end),
			gen_leader_mock:expect_cast(AMmock, fun({now_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			gen_server_mock:expect_cast(Connmock, fun({change_state, idle}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{idle, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", idle, wrapup, {}}, _State) -> ok end),
			?assertMatch({reply, ok, idle, _State}, wrapup(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({OldAgent, _AMmock, _Dmock, Monmock, Connmock, Assertmocks}) ->
		{"to idle with a release queued",
		fun() ->
			Agent = OldAgent#agent{queuedrelease = ?DEFAULT_REL},
			gen_server_mock:expect_cast(Connmock, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(Monmock, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, _}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, wrapup, ?DEFAULT_REL}, _State) -> ok end),
			?assertMatch({reply, ok, released, _State}, wrapup(idle, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to ringing",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({ringing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to precall",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({precall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to oncall",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({oncall, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to outgoing",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({outgoing, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with reason undefined",
		fun() ->
			?assertMatch({reply, ok, wrapup, #agent{queuedrelease = undefined}}, wrapup({released, undefined}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with default reason",
		fun() ->
			?assertMatch({reply, queued, wrapup, #agent{queuedrelease = ?DEFAULT_REL}}, wrapup({released, default}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with a valid reason",
		fun() ->
			?assertMatch({reply, queued, wrapup, #agent{queuedrelease = {"id", "reason", 0}}}, wrapup({released, {"id", "reason", 0}}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to released with a bad reason",
		fun() ->
			?assertMatch({reply, invalid, wrapup, #agent{queuedrelease = undefined}}, wrapup({released, "reason"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to warmtransfer",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({warmtransfer, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end,
	fun({Agent, _AMmock, _Dmock, _Monmock, _Connmock, Assertmocks}) ->
		{"to wrapup",
		fun() ->
			?assertMatch({reply, invalid, wrapup, _State}, wrapup({wrapup, "doesn't matter"}, "from", Agent)),
			Assertmocks()
		end}
	end]}.

init_test_() ->
	[{"agent_auth's mnesia tables not available",
	fun() ->
		catch agent_auth:stop(),
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		Agent = #agent{
			login = "testagent",
			skills = [],
			profile = error
		},
		?assertEqual({ok, released, Agent}, init([Agent, []]))
	end},
	{"agent should do logging of state changes",
	fun() ->
		Agent = #agent{
			login = "testagent",
			skills = [english]
		},
		{ok, released, Newagent} = init([Agent, [logging]]),
		?assert(is_pid(Newagent#agent.log_pid))
	end},
	{"agent has some magic skills that allow multiples.",
	fun() ->
		Agent = #agent{
			login = "testagent",
			skills = [{'_queue', "queue1"}, {'_queue', "queue2"}, {'_brand', "brandx"}, {'_brand', "brandy"}]
		},
		?assertMatch({ok, released, _NewAgent}, init([Agent, []])),
		{ok, released, #agent{skills = Skills}} = init([Agent, []]),
		lists:foreach(fun(E) ->
			?assert(lists:member(E, Agent#agent.skills))
		end, Skills)
	end},
	{"agent has some magic skills that should not be multiples of",
	fun() ->
		Agent = #agent{
			login = "testagent",
			skills = [{'_profile', "prof1"}, {'_profile', "prof2"}]
		},
		?assertError(badarg, init([Agent, []]))
	end}	].
	
generate_state() ->
	generate_state([{2, idle, "Idle"}, {3, ringing, "Ringing"}, {4, precall, "Precall"}, {5, oncall, "Oncall"}, {6, outgoing, "Outgoing"}, {7, released, "Released"}, {8, warmtransfer, "WarmTransfer"}, {9, wrapup, "Wrapup"}]).
generate_state([{Int, Atom, String}|T]) -> 
	[{"Automated test for " ++ integer_to_list(Int) ++ ", " ++ atom_to_list(Atom), 
		fun() -> 
			?assertEqual(Int, state_to_integer(Atom)),
			?assertEqual(Atom, integer_to_state(Int)),
			?assertEqual(Atom, list_to_state(String))
		end
		}|generate_state(T)];
generate_state([]) -> 
	[].

cross_check_state_test_() ->
	generate_state().

handle_sync_event_test_() ->
	{foreach,
	fun() ->
		ok
	end,
	fun(_) ->
		ok
	end,
	[fun(_) ->
		{"query state",
		fun() ->
			?assertMatch({reply, {ok, statename}, statename, "state"}, handle_sync_event(query_state, "from", statename, "state"))
		end}
	end,
	fun(_) ->
		{"set connectoin when connection is not defined",
		fun() ->
			{ok, Connmock} = gen_server_mock:new(),
			gen_server_mock:expect_cast(Connmock, fun({change_state, idle, undefined}, _State) -> ok end),
			Agent = #agent{
				login = "testagent",
				state = idle,
				statedata = undefined
			},
			?assertMatch({reply, ok, idle, #agent{connection = Connmock}}, handle_sync_event({set_connection, Connmock}, "from", idle, Agent)),
			gen_server_mock:assert_expectations(Connmock)
		end}
	end,
	fun(_) ->
		{"set connection when connection is already defined",
		fun() ->
			{ok, Curmock} = gen_server_mock:new(),
			{ok, Newmock} = gen_server_mock:new(),
			Agent = #agent{
				login = "testagent",
				state = idle,
				statedata = undefined,
				connection = Curmock
			},
			?assertMatch({reply, error, idle, #agent{connection = Curmock}}, handle_sync_event({set_connection, Newmock}, "from", idle, Agent)),
			gen_server_mock:assert_expectations(Curmock),
			gen_server_mock:assert_expectations(Newmock)
		end}
	end,
	fun(_) ->
		{"pop url",
		fun() ->
			{ok, Connmock} = gen_server_mock:new(),
			Agent = #agent{
				login = "testagent",
				state = idle,
				connection = Connmock
			},
			gen_server_mock:expect_cast(Connmock, fun({url_pop, "localhost", "ring"}, _State) -> ok end),
			?assertMatch({reply, ok, idle, _State}, handle_sync_event({url_pop, "localhost", "ring"}, "from", idle, Agent)),
			gen_server_mock:assert_expectations(Connmock)
		end}
	end,
	fun(_) ->
		{"garbage data",
		fun() ->
			?assertMatch({reply, ok, state, "state"}, handle_sync_event(<<"garbage data">>, "from", state, "state"))
		end}
	end]}.

handle_conn_exit_inband_test_() ->
	{foreach,
	fun() ->
		{ok, Callmock} = gen_server_mock:new(),
		{ok, Connmock} = gen_server_mock:new(),
		Call = #call{id = "test", source = Callmock, media_path = inband},
		{#agent{login = "test", connection = Connmock, statedata = Call}, Connmock}
	end,
	fun(_) ->
		ok
	end,
	[fun({A, P}) ->
		{"Death in idle",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, idle, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P}) ->
		{"Death in ringing",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, ringing, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P}) ->
		{"Death in precall",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, precall, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P}) ->
		{"Death in oncall",
		fun() ->
			#call{source = Callmock} = A#agent.statedata,
			gen_server_mock:expect_call(Callmock, fun('$gen_media_wrapup', _From, _State) -> ok end),
			Res = handle_info({'EXIT', P, "fail"}, oncall, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A#agent{connection = undefined}}, Res),
			gen_server_mock:assert_expectations(Callmock)
		end}
	end,
	fun({A, P}) ->
		{"Death in outgoing",
		fun() ->
			#call{source = Callmock} = A#agent.statedata,
			gen_server_mock:expect_call(Callmock, fun('$gen_media_wrapup', _From, _State) -> ok end),
			Res = handle_info({'EXIT', P, "fail"}, outgoing, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A#agent{connection = undefined}}, Res),
			gen_server_mock:assert_expectations(Callmock)
		end}
	end,
	fun({A, P}) ->
		{"Death in released",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, released, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P}) ->
		{"Death in warm transfer",
		fun() ->
			#call{source = Callmock} = Call = A#agent.statedata,
			Agent = A#agent{statedata = {onhold, Call, calling, "target"}},
			gen_server_mock:expect_call(Callmock, fun('$gen_media_wrapup', _From, _State) -> ok end),
			Res = handle_info({'EXIT', P, "fail"}, warmtransfer, Agent),
			?assertEqual({stop, {error, conn_exit, "fail"}, Agent#agent{connection = undefined}}, Res),
			gen_server_mock:assert_expectations(Callmock)
		end}
	end,
	fun({A, P}) ->
		{"Death in wrapup",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, wrapup, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end]}.

handle_conn_exit_outband_test_() ->
	{foreach,
	fun() ->
		{ok, Callpid} = dummy_media:start([{id, "test"}, {queues, none}]),
		Callrec = #call{id = "test", source = Callpid, media_path = outband},
		{#agent{login = "test", connection = self()}, self(), Callpid, Callrec}
	end,
	fun(_) ->
		ok
	end,
	[fun({A, P, _Mp, _C}) ->
		{"Death in idle",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, idle, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P, _Mp, _C}) ->
		{"Death in ringing",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, ringing, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P, _Mp, _C}) ->
		{"Death in precall",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, precall, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P, _Mp, C}) ->
		{"Death in oncall",
		fun() ->
			Agent = A#agent{statedata = C},
			Res = handle_info({'EXIT', P, "fail"}, oncall, Agent),
			?assertEqual({next_state, oncall, Agent#agent{connection = undefined}}, Res)
		end}
	end,
	fun({A, P, _Mp, C}) ->
		{"Death in outgoing",
		fun() ->
			Agent = A#agent{statedata = C},
			Res = handle_info({'EXIT', P, "fail"}, outgoing, Agent),
			?assertEqual({next_state, outgoing, Agent#agent{connection = undefined}}, Res)
		end}
	end,
	fun({A, P, _Mp, _C}) ->
		{"Death in released",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, released, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end,
	fun({A, P, _Mp, C}) ->
		{"Death in warm transfer",
		fun() ->
			Agent = A#agent{statedata = {onhold, C, calling, "target"}},
			Res = handle_info({'EXIT', P, "fail"}, warmtransfer, Agent),
			?assertEqual({next_state, warmtransfer, Agent#agent{connection = undefined}}, Res)
		end}
	end,
	fun({A, P, _Mp, _C}) ->
		{"Death in wrapup",
		fun() ->
			Res = handle_info({'EXIT', P, "fail"}, wrapup, A),
			?assertEqual({stop, {error, conn_exit, "fail"}, A}, Res)
		end}
	end]}.

handle_info_test_() ->
	{foreach,
	fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = gen_leader_mock:start(cpx_monitor),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		Client = #client{label = "testclient"},
		{ok, Mediapid} = gen_server_mock:new(),
		Callrec = #call{
			id = "testcall",
			source = Mediapid,
			client = Client
		},
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, state = wrapup, statedata = Callrec, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			gen_leader_mock:assert_expectations(Monmock),
			gen_server_mock:assert_expectations(Connmock),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		{Agent, Assertmocks}
	end,
	fun({Agent, _Assertmocks}) ->
		gen_server_mock:stop(whereis(dispatch_manager)),
		gen_leader_mock:stop(cpx_monitor),
		gen_server_mock:stop(Agent#agent.connection),
		gen_leader_mock:stop(agent_manager),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun({Agent, Assertmocks}) ->
		{"Hard end to idle",
		fun() ->
			Self = self(),
			gen_server_mock:expect_cast(dispatch_manager, fun({now_avail, Apid}, _State) ->
				Self = Apid,
				ok
			end),
			gen_leader_mock:expect_cast(agent_manager, fun({now_avail, Nom}, _State, _Elec) ->
				Nom = Agent#agent.login,
				ok
			end),
			gen_server_mock:expect_cast(Agent#agent.connection, fun({change_state, idle}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(cpx_monitor, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{idle, _Limits}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", idle, wrapup, {}}, _State) -> ok end),
			?assertMatch({next_state, idle, _State}, handle_info(end_wrapup, wrapup, Agent)),
			Assertmocks()
		end}
	end,
	fun({OldAgent, Assertmocks}) ->
		{"Hard end with queued release",
		fun() ->
			Agent = OldAgent#agent{queuedrelease = ?DEFAULT_REL},
			gen_server_mock:expect_cast(Agent#agent.connection, fun({change_state, released, ?DEFAULT_REL}, _State) ->
				ok
			end),
			gen_leader_mock:expect_leader_cast(cpx_monitor, fun({set, {{agent, "testid"}, Health, _Details, Node}}, _State, _Elec) ->
				[{released, _Limits}, {bias, _}] = Health,
				Node = node(),
				ok
			end),
			gen_server_mock:expect_info(Agent#agent.log_pid, fun({"testagent", released, wrapup, ?DEFAULT_REL}, _State) -> ok end),
			?assertMatch({next_state, released, _State}, handle_info(end_wrapup, wrapup, Agent)),
			Assertmocks()
		end}
	end,
	fun({OldAgent, Assertmocks}) ->
		{"hard wrapup comes in at wrong time",
		fun() ->
			Agent = OldAgent#agent{state = oncall},
			?assertEqual({next_state, oncall, Agent}, handle_info(end_wrapup, oncall, Agent))
		end}
	end]}.

-endif.
