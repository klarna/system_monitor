%%--------------------------------------------------------------------------------
%% Copyright 2020 Klarna Bank AB
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
%%% @doc
%%% Push monitoring events to Kafka
%%% @end
-module(system_monitor_kafka).

-behaviour(gen_server).

-include("sysmon_kafka.hrl").
-include("system_monitor.hrl").
-include_lib("brod/include/brod.hrl").

%% API
-export([start_link/0, produce/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state,
        { topic          :: brod:topic()
        }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Best effort attempt to push event to Kafka.
%% @end
%%--------------------------------------------------------------------
-spec produce(tuple()) -> ok.
produce(Event) ->
  gen_server:cast(?SERVER, {produce, Event}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() ->
          {ok, pid()} | ignore | {error, term()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  {ok, Topic} = application:get_env(?APP, kafka_topic),
  State = #state{topic = Topic},
  gen_server:cast(?SERVER, post_init),
  {ok, State}.

handle_call(_Msg, _From, State) ->
  {reply, {error, bad_call}, State}.

handle_cast(post_init, State) ->
  start_client(),
  {noreply, State};
handle_cast({produce, Term}, State) ->
  Payload = term_to_binary(Term),
  publish(State, Payload),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  stop_client().

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% (Re)start kafka client
%% @end
%%--------------------------------------------------------------------
-spec start_client() -> ok.
start_client() ->
  stop_client(),
  {ok, KafkaHosts} = application:get_env(?APP, kafka_hosts),
  case KafkaHosts of
    [] ->
      ok;
    _ ->
      {ok, ClientConfig} = application:get_env(?APP, kafka_client_config),
      ProducerConfig = [ {required_acks,               0}
                       , {retries,                     0}
                       , {max_linger_ms,               1000}
                       , {max_linger_count,            100}
                       , {topic_restart_delay_seconds, 5}
                       ],
      Ret = brod:start_client( KafkaHosts
                             , ?SYSMON_KAFKA_CLIENT
                             , [ {auto_start_producers, true}
                               , {default_producer_config, ProducerConfig}
                               | ClientConfig]
                             ),
      case Ret of
        ok ->
          ok;
        {error, {already_started, _}} ->
          ok;
        Error ->
          error_logger:warning_msg( "~p:start_client Failed to start "
                                    "kafka client: ~p~n"
                                  , [?MODULE, Error])
      end
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Ensure brod client stopped
%% @end
%%--------------------------------------------------------------------
-spec stop_client() -> ok.
stop_client() ->
  brod:stop_client(?SYSMON_KAFKA_CLIENT).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Push message to kafka
%%
%% @end
%%--------------------------------------------------------------------
-spec publish(#state{}, binary()) -> ok.
publish(State, Payload) ->
  brod:produce( ?SYSMON_KAFKA_CLIENT
              , State#state.topic
              , fun part_fun/4
              , <<"">>
              , Payload
              ),
  ok.

part_fun(_Topic, PartCount, Key, _Value) ->
  {ok, erlang:phash2(Key, PartCount)}.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
