-module(ergo_workspace_registry).
-behavior(gen_server).
%% API
-export([start_link/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, link_to/1, name_from_id/1, id_from_name/1]).

-export([register_name/2, unregister_name/1, whereis_name/1, whois_pid/1, send/2, normalize_name/1]).

-type(roletype() :: supervisor | build | server | graph | events).
-define(SERVER, ?MODULE).
-record(state, {item_index::integer(), registry}).
-record(registry_key, {workspace::binary(),role::roletype(),name::term()}).
-record(registration, {key::#registry_key{}|'_',pid::pid()|'_',monref::reference()|'_',index::binary()}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register_name({Workspace,Role,Name},Pid) ->
  gen_server:call(?SERVER, {register_name, reg_key_for(Workspace,Role,Name), Pid}).

unregister_name({Workspace,Role,Name}) ->
  gen_server:call(?SERVER, {unregister_name, reg_key_for(Workspace,Role,Name)}).

whereis_name({Workspace,Role,Name}) ->
  gen_server:call(?SERVER, {whereis_name, reg_key_for(Workspace,Role,Name)}).

whois_pid(Pid) ->
  gen_server:call(?SERVER, {whois_pid, Pid}).

send({Workspace,Role,Name}, Message) ->
  gen_server:call(?SERVER, {send, reg_key_for(Workspace,Role,Name), Message}).

name_from_id(Id) ->
  gen_server:call(?SERVER, {name_for_id, Id}).

id_from_name({Workspace,Role,Name}) ->
  gen_server:call(?SERVER, {process_id, reg_key_for(Workspace,Role,Name)}).

link_to(ViaTuple) ->
  link(whereis_name(ViaTuple)).

normalize_name(Workspace) ->
  filename:absname(Workspace).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  {ok, build_state()}.

handle_call({register_name, RegKey, Pid}, _From, State=#state{registry=RegTab,item_index=Index}) ->
  {reply, reg_name(RegKey, Pid, RegTab, Index), State#state{item_index=Index+1}};
handle_call({unregister_name, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, unreg_name(RegKey, RegTab), State};
handle_call({whereis_name, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, lookup(RegKey, RegTab), State};
handle_call({whois_pid, Pid}, _From, State=#state{registry=RegTab}) ->
  {reply, whois_pid(Pid, RegTab), State};
handle_call({send, RegKey, Message}, _From, State=#state{registry=RegTab}) ->
  {reply, send(RegKey, Message, RegTab), State};
handle_call({process_id, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, process_id(RegKey, RegTab), State};
handle_call({name_for_id, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, name_for_id(RegKey, RegTab), State};
handle_call(_, _, State) ->
  {reply, unknown_request, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({'DOWN', MonitorRef, process, Pid, _Info}, State) ->
  lost_pid(MonitorRef, Pid, State),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

reg_key_for(Workspace,Role,Name) ->
  #registry_key{workspace=normalize_name(Workspace),role=Role,name=Name}.

index_for(Role,Index) ->
  RoleB = erlang:atom_to_binary(Role, unicode),
  IndexB = erlang:integer_to_binary(Index),
  <<RoleB/binary,"_",IndexB/binary>>.

build_state() ->
  #state{item_index=1, registry=ets:new(ergo_registration, [set, {keypos, #registration.key}])}.

reg_name(RegKey=#registry_key{role=Role}, Pid, RegTab, Index) ->
  MonitorRef = monitor(process, Pid),
  Reg = #registration{key=RegKey, pid=Pid, monref=MonitorRef, index=index_for(Role,Index)},
  register_response(ets:insert(RegTab, Reg), Reg).

register_response(true, _Reg) -> yes;
register_response(_, #registration{monref=MonRef}) ->
  demonitor(MonRef),
  no.

lost_pid(MonRef, Pid, #state{registry=RegTab}) ->
  demonitor(MonRef),
  unreg_name(key_for_pid(Pid, RegTab), RegTab),
  ok.

whois_pid(Pid, RegTab) ->
  key_to_name(key_for_pid(Pid, RegTab)).

key_to_name(#registry_key{workspace=WS, role=R, name=N}) ->
  {WS, R, N};
key_to_name(unknown_pid) ->
  unknown_pid.

key_for_pid(Pid, RegTab) ->
  case ets:match_object(RegTab, #registration{pid=Pid, _='_'}) of
    [#registration{key=Key}|_Rest] -> Key;
    _ -> unknown_pid
  end.


unreg_name(RegKey, RegTab) ->
  ets:delete(RegTab, RegKey).

lookup(RegKey, RegTab) ->
  case ets:lookup(RegTab, RegKey) of
    [#registration{pid=Pid}|_Rest] -> Pid;
    [] -> undefined
  end.

process_id(RegKey, RegTab) ->
  case ets:lookup(RegTab, RegKey) of
    [#registration{index=Id}|_Rest] -> Id;
    _ -> {unknown_reg, RegKey}
  end.

name_for_id(ProcId, RegTab) ->
  Res = case ets:match_object(RegTab, #registration{index=ProcId, _='_'}) of
    [#registration{key=#registry_key{workspace=WS,role=R,name=N}}|_Rest] -> {WS,R,N};
    _ -> {unknown_name, ProcId, ets:tab2list(RegTab)}
  end,
  Res.

send(RegKey, Message, RegTab) ->
  case lookup(RegKey, RegTab) of
    undefined -> {bagarg, {RegKey, Message}};
    Pid -> Pid ! Message
  end.
