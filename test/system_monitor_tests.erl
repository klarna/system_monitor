-module(system_monitor_tests).

-include_lib("eunit/include/eunit.hrl").

start_test() ->
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  application:stop(system_monitor).
