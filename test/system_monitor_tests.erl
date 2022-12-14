-module(system_monitor_tests).

-include_lib("eunit/include/eunit.hrl").

start_test() ->
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  application:stop(system_monitor).

restart_pg_test() ->
  application:set_env(system_monitor, callback_mod, system_monitor_pg),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  ok = system_monitor_pg:stop(),
  ok = system_monitor_pg:start().
