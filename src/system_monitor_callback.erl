-module(system_monitor_callback).

-export([ start/0
        , stop/0
        , produce/2
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").

-callback start() -> ok.
-callback stop() -> ok.
-callback produce(atom(), list()) -> ok.

start() ->
  (get_callback_mod()):?FUNCTION_NAME().

stop() ->
  (get_callback_mod()):?FUNCTION_NAME().

produce(Type, Events) ->
  (get_callback_mod()):?FUNCTION_NAME(Type, Events).

-compile({inline, [get_callback_mod/0]}).
get_callback_mod() ->
  application:get_env(?APP, callback_mod, system_monitor_pg).
