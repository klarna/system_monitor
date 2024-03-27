%%--------------------------------------------------------------------------------
%% Copyright 2020 Klarna Bank AB
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------------------
%%% @doc
%%% Collect Erlang process statistics and push it to the configured destination
%%% @end
-module(system_monitor_top).

-behaviour(gen_server).

-include_lib("system_monitor/include/system_monitor.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif. % TEST

%% API
-export([start_link/0, get_app_top/0, get_abs_app_top/0,
         get_app_memory/0, get_app_processes/0,
         get_function_top/0, get_proc_top/0, get_proc_top/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export_type([function_top/0]).

-define(SERVER, ?MODULE).

-define(TOP_APP_TAB, sysmon_top_app_tab).
-define(TAB_OPTS, [private, named_table, set, {keypos, 1}]).

%% Type and record definitions

-record(state,
        { max_procs          :: integer()
        , sample_size        :: non_neg_integer()
        , interval           :: integer()
        , num_items          :: integer()
        , timer              :: timer:tref()
        , old_data           :: [#pid_info{}]
        , last_ts            :: integer()
        , proc_top = []      :: [#erl_top{}]
        , app_top = []       :: [#app_top{}]
        , function_top =
            #{ initial_call => []
             , current_function => []
             }               :: function_top()
        }).

-type top() :: {integer(), gb_trees:tree(integer(), [#pid_info{}])}.

-define(PROCESS_INFO_FIELDS_NEW,
        [ initial_call, dictionary, registered_name, group_leader, reductions, memory,
          message_queue_len, current_function]).

-define(PROCESS_INFO_FIELDS_UPDATE,
        [ reductions, memory, message_queue_len, current_function]).

-define(ADDITIONAL_FIELDS,
        [ stack_size
        , heap_size, total_heap_size, current_stacktrace
        ]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Get Erlang process top
%% @end
%%--------------------------------------------------------------------
-spec get_proc_top() -> {integer(), [#erl_top{}]}.
get_proc_top() ->
  {ok, Data} = gen_server:call(?SERVER, get_proc_top, infinity),
  Data.


%%--------------------------------------------------------------------
%% @doc
%% Get Erlang process top info for one process
%% @end
%%--------------------------------------------------------------------
-spec get_proc_top(pid()) -> #erl_top{} | false.
get_proc_top(Pid) ->
  gen_server:call(?SERVER, {get_proc_top, Pid}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% Get relative reduction utilization per application, sorted by
%% reductions
%% @end
%%--------------------------------------------------------------------
-spec get_app_top() -> [{atom(), float()}].
get_app_top() ->
  do_get_app_top(#app_top.red_rel).

%%--------------------------------------------------------------------
%% @doc
%% Get absolute reduction utilization per application, sorted by
%% reductions
%% @end
%%--------------------------------------------------------------------
-spec get_abs_app_top() -> [{atom(), integer()}].
get_abs_app_top() ->
  do_get_app_top(#app_top.red_abs).

%%--------------------------------------------------------------------
%% @doc
%% Get memory utilization per application, sorted by memory
%% @end
%%--------------------------------------------------------------------
-spec get_app_memory() -> [{atom(), integer()}].
get_app_memory() ->
  do_get_app_top(#app_top.memory).

%%--------------------------------------------------------------------
%% @doc
%% Get number of processes spawned by each application
%% @end
%%--------------------------------------------------------------------
-spec get_app_processes() -> [{atom(), integer()}].
get_app_processes() ->
  do_get_app_top(#app_top.processes).

%%--------------------------------------------------------------------
%% @doc
%% Get approximate distribution of initilal_call and current_function
%% per process
%% @end
%%--------------------------------------------------------------------
-spec get_function_top() -> function_top().
get_function_top() ->
  {ok, Data} = gen_server:call(?SERVER, get_function_top, infinity),
  Data.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() ->
          {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  {ok, MaxProcs} = application:get_env(?APP , top_max_procs),
  {ok, SampleSize} = application:get_env(?APP, top_sample_size),
  {ok, Interval} = application:get_env(?APP, top_sample_interval),
  {ok, NumItems} = application:get_env(?APP, top_num_items),
  {ok, TRef} = timer:send_after(0, collect_data),
  {ok, #state{ max_procs   = MaxProcs
             , sample_size = SampleSize
             , interval    = Interval
             , num_items   = NumItems
             , timer       = TRef
             , last_ts     = os:system_time()
             , old_data    = []
             }}.

handle_call(get_proc_top, _From, State) ->
  Top = State#state.proc_top,
  SnapshotTS = State#state.last_ts,
  Data = {SnapshotTS, Top},
  {reply, {ok, Data}, State};
handle_call({get_proc_top, Pid}, _From, State) ->
  Top = State#state.proc_top,
  {reply, lists:keyfind(pid_to_list(Pid), #erl_top.pid, Top), State};
handle_call(get_app_top, _From, State) ->
  Data = State#state.app_top,
  {reply, {ok, Data}, State};
handle_call(get_function_top, _From, State) ->
  Data = State#state.function_top,
  {reply, {ok, Data}, State};
handle_call(_Msg, _From, State) ->
  {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(collect_data, State) ->
  T1 = os:system_time(),
  NumProcesses = erlang:system_info(process_count),
  case should_calculate_info(NumProcesses, State#state.max_procs) of
    true ->
      T0 = State#state.last_ts,
      Dt = erlang:convert_time_unit(T1 - T0, native, microsecond),
      Pids = lists:sort(processes()),
      OldData = State#state.old_data,
      NewData = calc_deltas(OldData, Pids, Dt),
      ProcTop = do_proc_top(NewData, State, T1),
      AppTop = do_app_top(NewData);
    false ->
      AppTop = [],
      NewData = [],
      ProcTop = [fake_erl_top_msg(T1)]
  end,
  FunctionTop = process_aggregate(NewData, State#state.sample_size),
  %% Calculate timer interval. Sleep at least half a second between
  %% samples when sysmon is running very slow:
  T2 = os:system_time(),
  Dt2 = erlang:convert_time_unit(T2 - T1, native, microsecond),
  SleepTime = max(500, State#state.interval - Dt2),
  {ok, TRef} = timer:send_after(SleepTime, collect_data),
  {noreply, State#state{ last_ts      = T1
                       , old_data     = NewData
                       , proc_top     = ProcTop
                       , app_top      = AppTop
                       , function_top = FunctionTop
                       , timer        = TRef
                       }};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Calculate resource consumption per application
%% @end
%%--------------------------------------------------------------------
-spec do_app_top([#pid_info{}]) -> [#app_top{}].
do_app_top(Deltas) ->
  %% Prepare the temporary table:
  case ets:info(?TOP_APP_TAB) of
    undefined ->
      ets:new(?TOP_APP_TAB, ?TAB_OPTS);
    _ ->
      ets:delete_all_objects(?TOP_APP_TAB)
  end,
  %% Traverse process infos:
  lists:foreach(
    fun(#pid_info{group_leader = GL, dreductions = DR, memory=Mem}) ->
        ets:update_counter( ?TOP_APP_TAB
                          , GL
                          , [ {2, round(DR)}
                            , {3, Mem}
                            , {4, 1}
                            ]
                          , {GL, 0, 0, 0}
                          )
    end,
    Deltas),
  %% Calculate final values:
  TotalReds =
    ets:foldl(
      fun({_, DR, _, _}, Acc) ->
          Acc + DR
      end,
      0,
      ?TOP_APP_TAB),
  {AppInfo, UnknownReds, UnknownMem, UnknownProcs} =
    ets:foldl(
      fun( {GL, Reds, Mem, Procs}
         , {Apps, UnknownReds, UnknownMem, UnknownProcs}
         ) ->
          case application_controller:get_application(GL) of
            undefined ->
              { Apps
              , UnknownReds + Reds
              , UnknownMem + Mem
              , UnknownProcs + Procs
              };
            {ok, App} ->
              AppInfo = #app_top{ app = App
                                , red_rel = divide(Reds, TotalReds)
                                , red_abs = Reds
                                , memory = Mem
                                , processes = Procs
                                },
              {[AppInfo|Apps], UnknownReds, UnknownMem, UnknownProcs}
          end
      end,
      {[], 0, 0, 0},
      ?TOP_APP_TAB),
  UnknownApp = #app_top{ app       = unknown
                       , red_rel   = divide(UnknownReds, TotalReds)
                       , red_abs   = UnknownReds
                       , memory    = UnknownMem
                       , processes = UnknownProcs
                       },
  [UnknownApp|AppInfo].

divide(_A, 0) ->
  0;
divide(A, B) ->
  A / B.

%%------------------------------------------------------------------------------
%% @doc Produce an aggregate summary of initial call and current function for
%%      processes.
%%------------------------------------------------------------------------------
-spec process_aggregate([#pid_info{}], non_neg_integer()) -> function_top().
process_aggregate(ProcInfos0, SampleSize) ->
  ProcInfos = random_sample(ProcInfos0, SampleSize),
  NumProcs = length(ProcInfos),
  InitCallT = ets:new(sysmon_init_call, []),
  CurrFunT = ets:new(sysmon_curr_fun, []),
  Fun = fun(#pid_info{initial_call = InitCall, current_function = CurrFun0}) ->
            ets:update_counter(InitCallT, InitCall, {2, 1}, {InitCall, 0}),
            CurrFun =
              case CurrFun0 of
                %% process_info/2 may return 'undefined' in some
                %% cases (e.g.  native compiled (HiPE)
                %% modules). We collect all of these under
                %% {undefined, undefined, 0}.
                undefined -> {undefined, undefined, 0};
                _         -> CurrFun0
              end,
            ets:update_counter(CurrFunT, CurrFun, {2, 1}, {CurrFun, 0})
        end,
  lists:foreach(Fun, ProcInfos),
  Finalize = fun(A) ->
                 Sorted = lists:reverse(lists:keysort(2, ets:tab2list(A))),
                 lists:map(fun({Key, Val}) -> {Key, Val/NumProcs} end, Sorted)
             end,
  Result = #{ initial_call => Finalize(InitCallT)
            , current_function => Finalize(CurrFunT)
            },
  ets:delete(InitCallT),
  ets:delete(CurrFunT),
  Result.

%%--------------------------------------------------------------------
%% @doc
%% Find processes that take the most resources
%% @end
%%--------------------------------------------------------------------
-spec do_proc_top([#pid_info{}], #state{}, integer()) -> [#erl_top{}].
do_proc_top(Deltas, State, Now) ->
  NumElems = State#state.num_items,
  case length(Deltas) > NumElems of
    true ->
      {First, Rest} = lists:split(NumElems, Deltas);
    false ->
      First = Deltas,
      Rest = []
  end,
  %% Generate initial conditions for the top search using the first
  %% NumElems:
  Acc0 = { sort_top(#pid_info.dreductions, First)
         , sort_top(#pid_info.memory, First)
         , sort_top(#pid_info.dmemory, First)
         , sort_top(#pid_info.message_queue_len, First)
         },
  %% Iterate through the rest of the processes:
  TopGroups =
    lists:foldl(
      fun(Delta, {TopDRed, TopMem, TopDMem, TopMQ}) ->
          { maybe_push_to_top(#pid_info.dreductions, Delta, TopDRed)
          , maybe_push_to_top(#pid_info.memory, Delta, TopMem)
          , maybe_push_to_top(#pid_info.dmemory, Delta, TopDMem)
          , maybe_push_to_top(#pid_info.message_queue_len, Delta, TopMQ)
          }
      end,
      Acc0,
      Rest),
  %% Some pids may appear in more than one group, fix this:
  TopElems = lists:usort(
               lists:flatten(
                 [top_to_list(Grp) || Grp <- tuple_to_list(TopGroups)]
                )),
  %% Request additional data for the top processes:
  [finalize_proc_info(P, Now) || P <- TopElems].

-spec finalize_proc_info(#pid_info{}, integer()) -> #erl_top{}.
finalize_proc_info(#pid_info{pid = Pid, initial_call = InitialCall,
                             registered_name = Name,
                             group_leader = GL} = ProcInfo, Now) ->
  ProcessInfo = process_info(Pid, ?ADDITIONAL_FIELDS),
  case ProcessInfo of
    [{stack_size, Stack},
     {heap_size, Heap},
     {total_heap_size, Total},
     {current_stacktrace, Stacktrace}] ->
      CurrentFunction =
        case Stacktrace of
          [] ->
            {unknown, unknown, 0};
          [{CurrModule, CurrFun, CurrArity, _} | _] ->
            {CurrModule, CurrFun, CurrArity}
        end,
      #erl_top{node = system_monitor:node_name(),
               ts = Now,
               pid = pid_to_list(ProcInfo#pid_info.pid),
               group_leader = pid_to_list(GL),
               dreductions = ProcInfo#pid_info.dreductions,
               dmemory = ProcInfo#pid_info.dmemory,
               reductions = ProcInfo#pid_info.reductions,
               memory = ProcInfo#pid_info.memory,
               message_queue_len = ProcInfo#pid_info.message_queue_len,
               initial_call = InitialCall,
               registered_name = Name,
               stack_size = Stack,
               heap_size = Heap,
               total_heap_size = Total,
               current_stacktrace = Stacktrace,
               current_function = CurrentFunction};
    undefined ->
      #erl_top{node = system_monitor:node_name(),
               ts = Now,
               pid = pid_to_list(ProcInfo#pid_info.pid),
               group_leader = pid_to_list(GL),
               dreductions = ProcInfo#pid_info.dreductions,
               dmemory = ProcInfo#pid_info.dmemory,
               reductions = ProcInfo#pid_info.reductions,
               memory = ProcInfo#pid_info.memory,
               message_queue_len = ProcInfo#pid_info.message_queue_len,
               initial_call = {unknown, unknown, 0},
               current_function = {unknown, unknown, 0},
               stack_size = 0,
               heap_size = 0,
               total_heap_size = 0,
               current_stacktrace = []}
  end.

-spec maybe_push_to_top(integer(), #pid_info{}, top()) -> top().
maybe_push_to_top(FieldID, Val, {OldMin, OldTop}) ->
  Key = element(FieldID, Val),
  if OldMin < Key ->
      {SKey, SVal, Top1} = gb_trees:take_smallest(OldTop),
      case SVal of
        [_] ->
          Top2 = Top1;
        [_|SVal2] ->
          Top2 = gb_insert(SKey, SVal2, Top1)
      end,
      NewTop = gb_insert(Key, Val, Top2),
      {Minimal, _} = gb_trees:smallest(NewTop),
      {Minimal, NewTop};
    true ->
      {OldMin, OldTop}
  end.

-spec sort_top(integer(), [#pid_info{}]) -> top().
sort_top(Field, L) ->
  Top =
    lists:foldl(
      fun(Val, Acc) ->
          gb_insert(element(Field, Val), Val, Acc)
      end,
      gb_trees:empty(),
      L),
  {Minimal, _} = gb_trees:smallest(Top),
  {Minimal, Top}.

gb_insert(Key, Val, Tree) ->
  case gb_trees:lookup(Key, Tree) of
    none ->
      gb_trees:enter(Key, [Val], Tree);
    {value, Vals} ->
      gb_trees:update(Key, [Val|Vals], Tree)
  end.

-spec should_calculate_info(non_neg_integer(), integer()) -> boolean().
should_calculate_info(NumPids, MaxProcs) ->
  not (MaxProcs < NumPids andalso MaxProcs > 0).

pid_info_update(PI) ->
  #pid_info{pid = Pid} = PI,
  case should_not_update_memory(PI) of
    true ->
      %% Calling process_info(Pid, memory) can block both system_monitor and the
      %% monitored Pid for a long time, which can degrade system performance.
      %% If it seems dangerous to query memory, don't do that. The memory metric
      %% must be present if Pid's sample is present, so we set it to zero.
      case erlang:process_info(Pid, ?PROCESS_INFO_FIELDS_UPDATE -- [memory]) of
        [ {reductions, Reds}
        , {message_queue_len, MQL}
        , {current_function, CurFun}
        ] ->
          pid_info_update(PI, Reds, _Mem = 0, MQL, CurFun);
        undefined ->
          undefined
      end;
    false ->
      case erlang:process_info(Pid, ?PROCESS_INFO_FIELDS_UPDATE) of
        [ {reductions, Reds}
        , {memory, Mem}
        , {message_queue_len, MQL}
        , {current_function, CurFun}
        ] ->
          pid_info_update(PI, Reds, Mem, MQL, CurFun);
        undefined ->
          undefined
      end
  end.

pid_info_update(PI, Reds, Mem, MQL, CurFun) ->
  PI#pid_info{
    reductions = Reds
  , memory = Mem
  , message_queue_len = MQL
  , current_function = CurFun
  }.

should_not_update_memory(PI) ->
  %% this relies on number < atom in Erlang's term order
  PI#pid_info.message_queue_len > application:get_env(?APP, mql_limit_for_memory, undefined).

-spec pid_info_new(pid()) -> #pid_info{} | undefined.
pid_info_new(Pid) ->
  case erlang:process_info(Pid, ?PROCESS_INFO_FIELDS_NEW) of
    [ {initial_call, _} = InitialCallProp
    , {dictionary, _} = DictProp
    , {registered_name, RegisteredName}
    , {group_leader, GL}
    , {reductions, Red}
    , {memory, Mem}
    , {message_queue_len, MQ}
    , {current_function, CF}
    ] ->
      #pid_info{
         pid = Pid,
         initial_call = initial_call([InitialCallProp,DictProp]),
         registered_name = RegisteredName,
         group_leader = GL,
         reductions = Red,
         memory = Mem,
         message_queue_len = MQ,
         current_function = CF
        };
    undefined ->
      %% The proces has died while we were collecting other data...
      undefined
  end.

calc_deltas(OldData, Pids, Dt) ->
  NewData = calc_deltas(OldData, Pids, [], Dt),
  lists:filter(
    fun(undefined) -> false;
       (#pid_info{}) -> true
    end,
    NewData).

-spec calc_deltas(PIL, [pid()], PIL, number()) -> PIL
  when PIL :: [#pid_info{}].
calc_deltas([], New, Acc, Dt) ->
  %% The rest of the processess are new
  lists:sort([delta(undefined, pid_info_new(Pid), Dt) || Pid <- New] ++ Acc);
calc_deltas(_Old, [], Acc, _) ->
  %% The rest of the processes have terminated
  lists:sort(Acc);
calc_deltas(Old, Pids, Acc, Dt) ->
  [PI1 = #pid_info{pid = P1} | OldT] = Old,
  [P2 | PidsT] = Pids,
  if P1 > P2 -> %% P1 has terminated
      calc_deltas(OldT, Pids, Acc, Dt);
     P1 < P2 -> %% P2 is a new process
      Delta = delta(undefined, pid_info_new(P2), Dt),
      calc_deltas(Old, PidsT, [Delta|Acc], Dt);
     P1 =:= P2 -> %% We already have record of P2
      case pid_info_update(PI1) of
        undefined -> % P1 just terminated
          calc_deltas(OldT, PidsT, Acc, Dt);
        PI2 ->
          Delta = delta(PI1, PI2, Dt),
          calc_deltas(OldT, PidsT, [Delta|Acc], Dt)
      end
  end.

-spec top_to_list(top()) -> [#pid_info{}].
top_to_list({_, Top}) ->
  lists:append(gb_trees:values(Top)).

-spec delta(undefined, undefined, number()) -> undefined;
           (#pid_info{} | undefined, #pid_info{}, number()) -> #pid_info{}.
delta(undefined, undefined, _Dt) -> undefined;
delta(P1, P2, Dt) ->
  case P1 of
    undefined ->
      DRed = divide(P2#pid_info.reductions, Dt),
      DMem = divide(P2#pid_info.memory, Dt);
    _ ->
      DRed = divide((P2#pid_info.reductions - P1#pid_info.reductions), Dt),
      DMem = divide((P2#pid_info.memory - P1#pid_info.memory), Dt)
  end,
  P2#pid_info
    { dreductions = DRed
    , dmemory     = DMem
    }.

-spec do_get_app_top(integer()) -> [{atom(), number()}].
do_get_app_top(FieldId) ->
  {ok, Data} = gen_server:call(?SERVER, get_app_top, infinity),
  lists:reverse(
    lists:keysort(2, [{Val#app_top.app, element(FieldId, Val)}
                      || Val <- Data])).

-spec fake_erl_top_msg(integer()) -> #erl_top{}.
fake_erl_top_msg(Now) ->
  #erl_top{ node               = system_monitor:node_name()
          , ts                 = Now
          , pid                = "<42.42.42>"
          , group_leader       = "<42.42.42>"
          , dreductions        = 0
          , dmemory            = 0
          , reductions         = -1
          , memory             = -1
          , message_queue_len  = -1
          , initial_call       = {too_many, processes, 0}
          , registered_name    = error_too_many_processes
          , current_stacktrace = []
          , current_function   = {too_many, processes, 0}
          , stack_size         = -1
          , heap_size          = -1
          , total_heap_size    = -1
          }.

-spec random_sample(list(A), non_neg_integer()) -> list(A).
%% Note: actual sample size may slightly differ from
%% the SampleSize argument
random_sample([], _SampleSize)  -> [];
random_sample(L, SampleSize)  ->
  P = SampleSize/length(L),
  lists:filter(fun(_I) -> rand:uniform() < P end, L).

-spec initial_call(proplists:proplist()) -> mfa().
initial_call(Info)  ->
  case proplists:get_value(initial_call, Info) of
    {proc_lib, init_p, 5} ->
      proc_lib:translate_initial_call(Info);
    ICall ->
      ICall
  end.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

-dialyzer({nowarn_function, [ maybe_push_to_top_test/0
                            , maybe_push_to_top_same_as_sort_prop/0
                            , initial_call_test/0
                            , initial_call_fallback_test/0
                            ]}).

maybe_push_to_top_wrapper(Val, Top) ->
  Init = sort_top(1, Top),
  Result = top_to_list(maybe_push_to_top(1, Val, Init)),
  lists:sort(Result).

%% maybe_push_to_top function is just an optimized version
%% of sorting a list and then taking its first N elements.
%%
%% Check that it is indeed true
maybe_push_to_top_same_as_sort_prop() ->
  ?FORALL({Val, Top}, {{number()}, [{number()}]},
          begin
            NumElems = length(Top),
            PlainSort = lists:reverse(lists:sort([Val|Top])),
            Reference = lists:sublist(PlainSort, NumElems),
            Result = maybe_push_to_top_wrapper(Val, Top),
            Result == Reference
          end).

maybe_push_to_top_test() ->
  ?assertEqual(true, proper:quickcheck(
                       proper:numtests(
                         1000,
                         maybe_push_to_top_same_as_sort_prop())
                      )).

initial_call_test() ->
  GetProcInfo = fun(Pid) ->
                    erlang:process_info(Pid, [initial_call, dictionary])
                end,
  Pid1 = spawn(fun() -> timer:sleep(1000) end),
  timer:sleep(100), %% Sleep to avoid race condition
  ?assertEqual( {erlang, apply, 2}
              , initial_call(GetProcInfo(Pid1))
              ),
  Pid2 = proc_lib:spawn(timer, sleep, [1000]),
  timer:sleep(100),  %% Sleep to avoid race condition
  ?assertEqual( {timer, sleep, 1}
              , initial_call(GetProcInfo(Pid2))
              ).

initial_call_fallback_test() ->
  GetProcInfo = fun(Pid) ->
                    erlang:process_info(Pid, [initial_call])
                end,
  Pid1 = spawn(fun() -> timer:sleep(1000) end),
  timer:sleep(100), %% Sleep to avoid race condition
  ?assertEqual( {erlang, apply, 2}
              , initial_call(GetProcInfo(Pid1))
              ),
  Pid2 = proc_lib:spawn(timer, sleep, [1000]),
  timer:sleep(100),  %% Sleep to avoid race condition
  ?assertEqual( {proc_lib, init_p, 5}
              , initial_call(GetProcInfo(Pid2))
              ).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
