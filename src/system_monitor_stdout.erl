-module(system_monitor_stdout).

-export([ start/0
        , stop/1
        , produce/2
        ]).

-include_lib("hut/include/hut.hrl").

start() ->
  [].

stop(_State) ->
  ok.

produce(Events, _State) ->
  lists:foreach(fun(Event) ->
                   ?log(info, "System monitor event: ~p", [Event], #{domain => [system_monitor]})
                end,
                Events).
