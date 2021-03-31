-module(system_monitor_callback).

-export([ child_spec/0
        , produce/1
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").

-callback child_spec() -> supervisor3:child_spec() | [].
-callback produce(list()) -> ok.

-optional_callbacks([ child_spec/0 ]).

child_spec() ->
  {ok, Mod} = application:get_env(?APP, callback_mod),
  code:ensure_loaded(Mod),
  case erlang:function_exported(Mod, ?FUNCTION_NAME, ?FUNCTION_ARITY) of
    true ->
      Mod:?FUNCTION_NAME();
    false ->
      []
  end.

produce(Events) ->
  (application:get_env(?APP, callback_mod)):?FUNCTION_NAME(Events).
