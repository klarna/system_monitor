%% -*- erlang-indent-level: 2 -*-
%%%-------------------------------------------------------------------
%%% File    : system_monitor.erl
%%% Description : Monitor for some system parameters.
%%%
%%% Created : 20 Dec 2011 by Thomas Jarvstrand <>
%%%-------------------------------------------------------------------
%% @private
-module(system_monitor).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include_lib("system_monitor/include/system_monitor.hrl").

-include_lib("hut/include/hut.hrl").

%% API
-export([start_link/0]).

-export([reset/0]).

-export([ report_full_status/0
        , check_process_count/0
        , self_monitor/0
        , start_top/0
        , stop_top/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-include_lib("hut/include/hut.hrl").

-define(SERVER, ?MODULE).
-define(TICK_INTERVAL, 1000).


-record(state, { monitors = []
               , timer_ref
               }).

%% System monitor is started early, some application may be
%% unavalable
-define(MAYBE(Prog), try Prog catch _:_ -> undefined end).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Start printing erlang top to console
%%--------------------------------------------------------------------
-spec start_top() -> ok.
start_top() ->
  application:set_env(?APP, top_printing, group_leader()).

%%--------------------------------------------------------------------
%% @doc Stop printing erlang top to console
%%--------------------------------------------------------------------
-spec stop_top() -> ok.
stop_top() ->
  application:set_env(?APP, top_printing, false).

%%--------------------------------------------------------------------
%% @doc Reset monitors
%%--------------------------------------------------------------------
-spec reset() -> ok.
reset() ->
  gen_server:cast(?SERVER, reset).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
  {ok, Timer} = timer:send_interval(?TICK_INTERVAL, {self(), tick}),
  {ok, #state{ monitors = init_monitors()
             , timer_ref = Timer
             }}.

handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

handle_cast(reset, State) ->
  {noreply, State#state{monitors = init_monitors()}};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({Self, tick}, State) when Self =:= self() ->
  Monitors = [case Ticks - 1 of
                0 ->
                  try
                    apply(Module, Function, [])
                  catch
                    EC:Error:Stack ->
                      error_logger:warning_msg(
                        "system_monitor ~p crashed:~n~p:~p~nStacktrace: ~p~n",
                        [{Module, Function}, EC, Error, Stack])
                  end,
                  {Module, Function, F, TicksReset, TicksReset};
                TicksDecremented ->
                  {Module, Function, F, TicksReset, TicksDecremented}
              end || {Module, Function,
                      F, TicksReset, Ticks} <- State#state.monitors],
  {noreply, State#state{monitors = Monitors}};
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate(term(), #state{}) -> any().
terminate(_Reason, State) ->
  %% Possibly, one last check.
  [apply(?MODULE, Monitor, []) ||
    {Monitor, true, _TicksReset, _Ticks} <- State#state.monitors].

%%==============================================================================
%% Internal functions
%%==============================================================================

%%------------------------------------------------------------------------------
%% @doc Returns the list of initiated monitors.
%%------------------------------------------------------------------------------
-spec init_monitors() -> [{module(), function(), boolean(),
                           pos_integer(), pos_integer()}].
init_monitors() ->
  [{Module, Function, F, Ticks, Ticks} ||
    {Module, Function, F, Ticks} <- monitors()].

%%------------------------------------------------------------------------------
%% @doc Returns the list of monitors. The format is
%%      {FunctionName, RunMonitorAtTerminate, NumberOfTicks}.
%%      RunMonitorAtTerminate determines whether the monitor is to be run in
%%      the terminate gen_server callback.
%%      ... and NumberOfTicks is the number of ticks between invocations of
%%      the monitor in question. So, if NumberOfTicks is 3600, the monitor is
%%      to be run once every hour, as there is a tick every second.
%%------------------------------------------------------------------------------
-spec monitors() -> [{module(), function(), boolean(), pos_integer()}].
monitors() ->
  {ok, AdditionalMonitors} = application:get_env(system_monitor, status_checks),
  {ok, TopInterval} = application:get_env(?APP, top_sample_interval),
  [ {?MODULE, check_process_count,  true,  2}
  , {?MODULE, self_monitor,         false, 5}
  , {?MODULE, report_full_status,   false, TopInterval div 1000}
  ] ++ AdditionalMonitors.

%%------------------------------------------------------------------------------
%% @doc
%% Monitor mailbox size of system_monitor_kafka process
%%
%% Check message queue length of this process and kill it when it's growing
%% uncontrollably. It is needed because this process doesn't have backpressure
%% by design
%% @end
%%------------------------------------------------------------------------------
self_monitor() ->
  message_queue_sentinel(system_monitor_kafka, 3000).

-spec message_queue_sentinel(atom() | pid(), integer()) -> ok.
message_queue_sentinel(Name, Limit) when is_atom(Name) ->
  case whereis(Name) of
    Pid when is_pid(Pid) ->
      message_queue_sentinel(Pid, Limit);
    _ ->
      ok
  end;
message_queue_sentinel(Pid, Limit) when is_pid(Pid) ->
  case process_info(Pid, [message_queue_len, current_function]) of
    [{message_queue_len, Len}, {current_function, Fun}] when Len >= Limit ->
      ?log( warning
          , "Abnormal message queue length (~p). "
            "Process ~p (~p) will be terminated."
          , [Len, Pid, Fun]
          , #{domain => [system_monitor]}
          ),
      exit(Pid, kill);
    _ ->
      ok
  end.

%%------------------------------------------------------------------------------
%% Monitor for number of processes
%%------------------------------------------------------------------------------

%%------------------------------------------------------------------------------
%% @doc Check the number of processes and log an aggregate summary of the
%%      process info if the count is above Threshold.
%%------------------------------------------------------------------------------
-spec check_process_count() -> ok.
check_process_count() ->
  {ok, MaxProcs} = application:get_env(?APP, top_max_procs),
  case erlang:system_info(process_count) of
    Count when Count > MaxProcs div 5 ->
      ?log( warning
          , "Abnormal process count (~p).~n"
          , [Count]
          , #{domain => [system_monitor]}
          );
    _ -> ok
  end.

%%------------------------------------------------------------------------------
%% @doc Report top processes
%%------------------------------------------------------------------------------
-spec report_full_status() -> ok.
report_full_status() ->
  %% `TS' variable should be used consistently in all following
  %% reports for this time interval, so it can be used as a key to
  %% lookup the relevant events
  {TS, ProcTop} = system_monitor_top:get_proc_top(),
  push_to_kafka(ProcTop),
  report_app_top(TS),
  %% Node status report goes last, and it "seals" the report for this
  %% time interval:
  NodeReport =
    case application:get_env(?APP, node_status_fun) of
      {ok, {Module, Function}} ->
        try Module:Function()
        catch _:_ -> <<>> end;
      _ ->
        <<>>
    end,
  system_monitor_kafka:produce({node_role, node(), TS, iolist_to_binary(NodeReport)}).

%%------------------------------------------------------------------------------
%% @doc Calculate reductions per application.
%%------------------------------------------------------------------------------
-spec report_app_top(erlang:timestamp()) -> ok.
report_app_top(TS) ->
  AppReds  = system_monitor_top:get_abs_app_top(),
  present_results(app_top, reductions, AppReds, TS),
  AppMem   = system_monitor_top:get_app_memory(),
  present_results(app_top, memory, AppMem, TS),
  AppProcs = system_monitor_top:get_app_processes(),
  present_results(app_top, processes, AppProcs, TS),
  #{ current_function := CurrentFunction
   , initial_call := InitialCall
   } = system_monitor_top:get_function_top(),
  present_results(fun_top, current_function, CurrentFunction, TS),
  present_results(fun_top, initial_call, InitialCall, TS),
  ok.

%%--------------------------------------------------------------------
%% @doc Push app_top or fun_top information to kafka
%%--------------------------------------------------------------------
present_results(Record, Tag, Values, TS) ->
  {ok, Thresholds} = application:get_env(?APP, top_significance_threshold),
  Threshold = maps:get(Tag, Thresholds, 0),
  Node = node(),
  [system_monitor_kafka:produce({Record, Node, TS, Key, Tag, Val})
   || {Key, Val} <- Values, Val > Threshold].

%%--------------------------------------------------------------------
%% @doc Push plain records to Kafka
%%--------------------------------------------------------------------
-spec push_to_kafka([term()]) -> ok.
push_to_kafka(L) ->
  lists:foreach(fun system_monitor_kafka:produce/1, L).
