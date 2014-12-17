-module(erdo_workspace_registry).
-behavior(gen_server).
%% API
-export([start_link/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, link_to/1]).

-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).

-type(roletype() :: supervisor | build | server | graph | events).
-define(SERVER, ?MODULE).
-record(state, {registry}).
-record(registry_key, {workspace::atom(),role::roletype(),name::term()}).
-record(registration, {key::#registry_key{},pid::pid()}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register_name({Workspace,Role,Name},Pid) ->
  gen_server:call(?SERVER, {register_name, reg_key_for(Workspace,Role,Name), Pid}).

unregister_name({Workspace,Role,Name}) ->
  gen_server:call(?SERVER, {unregister_name, reg_key_for(Workspace,Role,Name)}).

whereis_name({Workspace,Role,Name}) ->
  gen_server:call(?SERVER, {whereis_name, reg_key_for(Workspace,Role,Name)}).

send({Workspace,Role,Name}, Message) ->
  gen_server:call(?SERVER, {send, reg_key_for(Workspace,Role,Name), Message}).

link_to(ViaTuple) ->
  link(whereis_name(ViaTuple)).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  {ok, build_state()}.

handle_call({register_name, RegKey, Pid}, _From, State=#state{registry=RegTab}) ->
  {reply, reg_name(RegKey, Pid, RegTab), State};
handle_call({unregister_name, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, unreg_name(RegKey, RegTab), State};
handle_call({whereis_name, RegKey}, _From, State=#state{registry=RegTab}) ->
  {reply, lookup(RegKey, RegTab), State};
handle_call({send, RegKey, Message}, _From, State=#state{registry=RegTab}) ->
  {reply, send(RegKey, Message, RegTab), State};
handle_call(_Request, _From, State) ->
  {reply, unknown_request, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

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
  #registry_key{workspace=Workspace,role=Role,name=Name}.

build_state() ->
  #state{registry=ets:new(erdo_registration, set, {keypos, #registration.key})}.

reg_name(RegKey, Pid, RegTab) ->
  ets:insert(RegTab, #registration{key=RegKey, pid=Pid}).

unreg_name(RegKey, RegTab) ->
  ets:delete(RegTab, RegKey).

lookup(RegKey, RegTab) ->
  case hd(ets:lookup(RegTab, RegKey)) of
    #registration{pid=Pid} -> Pid;
    _ -> unknown
  end.

send(RegKey, Message, RegTab) ->
  case lookup(RegKey, RegTab) of
    unknown -> {bagarg, {RegKey, Message}};
    Pid -> Pid ! Message
  end.
