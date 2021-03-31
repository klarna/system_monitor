-module(system_monitor_callback).

-export([ start/0
        , stop/1
        , produce/2
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").

-callback start() -> any().
-callback stop(any()) -> ok.
-callback produce(list(), any()) -> ok.

start() ->
  (application:get_env(?APP, callback_mod, system_monitor_stdout)):?FUNCTION_NAME().

stop(State) ->
  (application:get_env(?APP, callback_mod, system_monitor_stdout)):?FUNCTION_NAME(State).

produce(Events, State) ->
  (application:get_env(?APP, callback_mod, system_monitor_stdout)):?FUNCTION_NAME(Events, State).
