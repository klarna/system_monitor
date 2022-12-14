-module(system_monitor_tests).

-include_lib("eunit/include/eunit.hrl").

start_test() ->
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  application:stop(system_monitor).

callback_is_started_when_configured_test() ->
  application:set_env(system_monitor, callback_mod, system_monitor_pg),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  ?assertNotEqual(undefined, whereis(system_monitor_pg)),
  application:stop(system_monitor).

callback_is_started_test() ->
  application:unset_env(system_monitor, callback_mod),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  ?assertEqual(undefined, whereis(system_monitor_pg)),
  application:stop(system_monitor).
