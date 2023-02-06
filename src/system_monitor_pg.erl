%%--------------------------------------------------------------------------------
%% Copyright 2021 Klarna Bank AB
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
-module(system_monitor_pg).

-behaviour(gen_server).
-export([ start_link/0
        , init/1
        , handle_continue/2
        , handle_call/3
        , handle_info/2
        , handle_cast/2
        , format_status/2
        , terminate/2
        ]).

-behaviour(system_monitor_callback).
-export([ produce/2 ]).

-include_lib("system_monitor/include/system_monitor.hrl").
-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(FIVE_SECONDS, 5000).
-define(ONE_HOUR, 60*60*1000).

%%%_* API =================================================================
produce(Type, Events) ->
  gen_server:cast(?SERVER, {produce, Type, Events}).

%%%_* Callbacks =================================================================
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init(_Args) ->
  erlang:process_flag(trap_exit, true),
  {ok, #{}, {continue, start_pg}}.

handle_continue(start_pg, State) ->
  Conn = initialize(),
  case Conn of
    undefined ->
      timer:send_after(?FIVE_SECONDS, reinitialize);
    Conn ->
      ok
  end,
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State#{connection => Conn, buffer => buffer_new()}}.

handle_call(_Msg, _From, State) ->
  {reply, ok, State}.

handle_info({'EXIT', Conn, _Reason}, #{connection := Conn} = State) ->
  timer:send_after(?FIVE_SECONDS, reinitialize),
  {noreply, State#{connection => undefined}};
handle_info({'EXIT', _Conn, _Reason}, #{connection := undefined} = State) ->
  timer:send_after(?FIVE_SECONDS, reinitialize),
  {noreply, State};
handle_info({'EXIT', _Conn, normal}, State) ->
  {noreply, State};
handle_info(mk_partitions, #{connection := undefined} = State) ->
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State};
handle_info(mk_partitions, #{connection := Conn} = State) ->
  mk_partitions(Conn),
  timer:send_after(?ONE_HOUR, mk_partitions),
  {noreply, State};
handle_info(reinitialize, State) ->
  {noreply, State#{connection => initialize()}}.

handle_cast({produce, Type, Events}, #{connection := undefined, buffer := Buffer} = State) ->
  {noreply, State#{buffer => buffer_add(Buffer, {Type, Events})}};
handle_cast({produce, Type, Events}, #{connection := Conn, buffer := Buffer} = State) ->
  MaxMsgQueueSize = application:get_env(?APP, max_message_queue_len, 1000),
  case process_info(self(), message_queue_len) of
    {_, N} when N > MaxMsgQueueSize ->
      {noreply, State};
    _ ->
      lists:foreach(fun({Type0, Events0}) ->
                      run_query(Conn, Type0, Events0)
                    end, buffer_to_list(buffer_add(Buffer, {Type, Events}))),
      {noreply, State#{buffer => buffer_new()}}
  end.

format_status(normal, [_PDict, State]) ->
  [{data, [{"State", State}]}];
format_status(terminate, [_PDict, State]) ->
  State#{buffer => buffer_new()}.

terminate(_Reason, #{connection := undefined}) ->
  ok;
terminate(_Reason, #{connection := Conn}) ->
  epgsql:close(Conn).

%%%_* Internal buffer functions ===============================================
buffer_new() ->
  {0, queue:new()}.

buffer_add({Len, Buffer}, Element) ->
  MaxBufferSize = application:get_env(?APP, max_buffer_size, 1000),
  case Len >= MaxBufferSize of
    true -> {Len, queue:in(Element, queue:drop(Buffer))};
    false -> {Len + 1, queue:in(Element, Buffer)}
  end.

buffer_to_list({_, Buffer}) ->
  queue:to_list(Buffer).

%%%_* Internal functions ======================================================
run_query(Conn, Type, Events) ->
  {ok, Statement} = epgsql:parse(Conn, query(Type)),
  Batch = [{Statement, params(Type, I)} || I <- Events],
  Results = epgsql:execute_batch(Conn, Batch),
  %% Crash on failure
  lists:foreach(fun ({ok, _}) ->
                      ok;
                    ({ok, _, _}) ->
                      ok
                end,
                Results).

initialize() ->
  case connect() of
    undefined ->
      log_failed_connection(),
      undefined;
    Conn ->
      mk_partitions(Conn),
      Conn
  end.

connect() ->
  case epgsql:connect(connect_options()) of
    {ok, Conn} ->
      Conn;
    _ ->
      undefined
  end.

connect_options() ->
  #{host => application:get_env(?APP, db_hostname, "localhost"),
    port => application:get_env(?APP, db_port, 5432),
    username => application:get_env(?APP, db_username, "system_monitor"),
    password => application:get_env(?APP, db_password, "system_monitor_password"),
    database => application:get_env(?APP, db_name, "system_monitor"),
    timeout => application:get_env(?APP, db_connection_timeout, 5000),
    codecs => []}.

log_failed_connection() ->
  ?LOG_WARNING("Failed to open connection to the DB.", [], #{domain => [system_monitor]}).

mk_partitions(Conn) ->
  DaysAhead = application:get_env(system_monitor, partition_days_ahead, 10),
  DaysBehind = application:get_env(system_monitor, partition_days_behind, 10),
  GDate = calendar:date_to_gregorian_days(date()),
  DaysAheadL = lists:seq(GDate, GDate + DaysAhead),
  %% Delete 10 days older than partition_days_behind config
  DaysBehindL = lists:seq(GDate - DaysBehind - 10, GDate - DaysBehind - 1),
  lists:foreach(fun(Day) -> create_partition_tables(Conn, Day) end, DaysAheadL),
  lists:foreach(fun(Day) -> delete_partition_tables(Conn, Day) end, DaysBehindL).

create_partition_tables(Conn, Day) ->
  Tables = [<<"prc">>, <<"app_top">>, <<"fun_top">>, <<"node_role">>],
  From = to_postgres_date(Day),
  To = to_postgres_date(Day + 1),
  lists:foreach(fun(Table) ->
                   Query = create_partition_query(Table, Day, From, To),
                   [{ok, [], []}, {ok, [], []}] = epgsql:squery(Conn, Query)
                end,
                Tables).

delete_partition_tables(Conn, Day) ->
  Tables = [<<"prc">>, <<"app_top">>, <<"fun_top">>, <<"node_role">>],
  lists:foreach(fun(Table) ->
                   Query = delete_partition_query(Table, Day),
                   {ok, [], []} = epgsql:squery(Conn, Query)
                end,
                Tables).

create_partition_query(Table, Day, From, To) ->
  <<"CREATE TABLE IF NOT EXISTS ", Table/binary, "_", (integer_to_binary(Day))/binary, " ",
    "PARTITION OF ", Table/binary, " ",
    "FOR VALUES "
    "FROM ('", (list_to_binary(From))/binary, "') TO ('", (list_to_binary(To))/binary, "');"
    "CREATE INDEX IF NOT EXISTS ",
    Table/binary, "_", (integer_to_binary(Day))/binary, "_ts_idx "
    "ON ", Table/binary, "_", (integer_to_binary(Day))/binary, "(ts);">>.

delete_partition_query(Table, Day) ->
  <<"DROP TABLE IF EXISTS ", Table/binary, "_", (integer_to_binary(Day))/binary, ";">>.

to_postgres_date(GDays) ->
  {YY, MM, DD} = calendar:gregorian_days_to_date(GDays),
  lists:flatten(io_lib:format("~w-~2..0w-~2..0w", [YY, MM, DD])).

query(fun_top) ->
  fun_top_query();
query(app_top) ->
  app_top_query();
query(node_role) ->
  node_role_query();
query(proc_top) ->
  prc_query().

prc_query() ->
  <<"insert into prc (node, ts, pid, dreductions, dmemory, reductions, "
    "memory, message_queue_len, current_function, initial_call, "
    "registered_name, stack_size, heap_size, total_heap_size, current_stacktrace, group_leader) "
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16);">>.

app_top_query() ->
  <<"insert into app_top (node, ts, application, unit, value) VALUES ($1, $2, $3, $4, $5);">>.

fun_top_query() ->
  <<"insert into fun_top (node, ts, fun, fun_type, num_processes) VALUES ($1, $2, $3, $4, $5);">>.

node_role_query() ->
  <<"insert into node_role (node, ts, data) VALUES ($1, $2, $3);">>.

params(fun_top, {fun_top, Node, TS, Key, Tag, Val} = _Event) ->
  [atom_to_list(Node), ts_to_timestamp(TS), system_monitor:fmt_mfa(Key), Tag, Val];
params(app_top, {app_top, Node, TS, Application, Tag, Val} = _Event) ->
  [atom_to_list(Node),
   ts_to_timestamp(TS),
   atom_to_list(Application),
   atom_to_list(Tag),
   Val];
params(node_role, {node_role, Node, TS, Bin}) ->
  [atom_to_list(Node), ts_to_timestamp(TS), Bin];
params(proc_top,
       #erl_top{node = Node,
                ts = TS,
                pid = Pid,
                dreductions = DR,
                dmemory = DM,
                reductions = R,
                memory = M,
                message_queue_len = MQL,
                current_function = CF,
                initial_call = IC,
                registered_name = RN,
                stack_size = SS,
                heap_size = HS,
                total_heap_size = THS,
                current_stacktrace = CS,
                group_leader = GL} =
         _Event) ->
  [atom_to_list(Node),
   ts_to_timestamp(TS),
   Pid,
   DR,
   DM,
   R,
   M,
   MQL,
   system_monitor:fmt_mfa(CF),
   system_monitor:fmt_mfa(IC),
   name_to_list(RN),
   SS,
   HS,
   THS,
   system_monitor:fmt_stack(CS),
   GL].

ts_to_timestamp(TS) ->
  calendar:system_time_to_universal_time(TS, native).

name_to_list(Term) ->
  case io_lib:printable_latin1_list(Term) of
    true ->
      Term;
    false ->
      lists:flatten(io_lib:format("~p", [Term]))
  end.
