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

-module(system_monitor_callback).

-export([ produce/2
        , is_configured/0
        , get_callback_mod/0
        ]).

-include_lib("system_monitor/include/system_monitor.hrl").

-callback produce(atom(), list()) -> ok.

produce(Type, Events) ->
  (get_callback_mod()):?FUNCTION_NAME(Type, Events).

-compile({inline, [get_callback_mod/0]}).
get_callback_mod() ->
  application:get_env(?APP, callback_mod, undefined).

is_configured() ->
  get_callback_mod() =/= undefined.
