-module(system_monitor_tests).

-include_lib("eunit/include/eunit.hrl").

%% Acts as the `external_monitoring' callback module in the tests below.
-export([system_monitor_event/2]).

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

%%====================================================================
%% external_monitoring
%%====================================================================

external_monitoring_unset_test() ->
  application:unset_env(system_monitor, external_monitoring),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  send_beam_event_and_assert_alive(),
  application:stop(system_monitor).

%% `undefined' is how `system_monitor.app.src' spells "not configured" for
%% `node_status_fun' and `db_password_fun', and it is the default this option
%% now ships with. Spelling it that way used to reach `{ok, Mod}' with
%% `Mod = undefined' and call `undefined:system_monitor_event/2', which took
%% the event monitor down once per BEAM event.
external_monitoring_undefined_test() ->
  application:set_env(system_monitor, external_monitoring, undefined),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  send_beam_event_and_assert_alive(),
  application:stop(system_monitor).

external_monitoring_is_called_test() ->
  application:set_env(system_monitor, external_monitoring, ?MODULE),
  ?assertMatch({ok, _}, application:ensure_all_started(system_monitor)),
  true = register(sysmon_test_listener, self()),
  try
    send_beam_event_and_assert_alive(),
    receive
      {sysmon_event, EventKind, Info} ->
        ?assertEqual(long_gc, EventKind),
        ?assertEqual([{timeout, 100}], Info)
    after 1000 ->
        ?assert(external_monitoring_callback_was_not_called)
    end
  after
    unregister(sysmon_test_listener),
    application:unset_env(system_monitor, external_monitoring),
    application:stop(system_monitor)
  end.

%%====================================================================
%% Helpers
%%====================================================================

%% The `external_monitoring' callback. Runs inside `system_monitor_events'.
system_monitor_event(EventKind, Info) ->
  case whereis(sysmon_test_listener) of
    undefined -> ok;
    Pid -> Pid ! {sysmon_event, EventKind, Info}
  end,
  ok.

%% Feed `system_monitor_events' the message shape `erlang:system_monitor/2'
%% delivers, then confirm the process is still the one that received it.
%%
%% The call is addressed to the pid rather than to the registered name on
%% purpose: the process is supervised, so a restart would put a fresh process
%% under the same name and a name-addressed call would answer happily from it.
%% Calls are also handled after the event message, so a reply is proof that the
%% event was handled without taking the process down.
send_beam_event_and_assert_alive() ->
  Pid = whereis(system_monitor_events),
  Pid ! {monitor, self(), long_gc, [{timeout, 100}]},
  ?assertEqual({error, unknown_call}, gen_server:call(Pid, ping)).
