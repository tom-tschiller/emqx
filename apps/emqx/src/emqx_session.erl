%%--------------------------------------------------------------------
%% Copyright (c) 2017-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% A stateful interaction between a Client and a Server. Some Sessions
%% last only as long as the Network Connection, others can span multiple
%% consecutive Network Connections between a Client and a Server.
%%
%% The Session State in the Server consists of:
%%
%% The existence of a Session, even if the rest of the Session State is empty.
%%
%% The Clients subscriptions, including any Subscription Identifiers.
%%
%% QoS 1 and QoS 2 messages which have been sent to the Client, but have not
%% been completely acknowledged.
%%
%% QoS 1 and QoS 2 messages pending transmission to the Client and OPTIONALLY
%% QoS 0 messages pending transmission to the Client.
%%
%% QoS 2 messages which have been received from the Client, but have not been
%% completely acknowledged.The Will Message and the Will Delay Interval
%%
%% If the Session is currently not connected, the time at which the Session
%% will end and Session State will be discarded.
%% @end
%%--------------------------------------------------------------------

%% MQTT Session
-module(emqx_session).

-include("logger.hrl").
-include("types.hrl").
-include("emqx.hrl").
-include("emqx_session.hrl").
-include("emqx_mqtt.hrl").

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-export([
    create/2,
    open/2,
    destroy/1,
    destroy/2
]).

-export([
    info/1,
    info/2,
    stats/1
]).

-export([
    subscribe/4,
    unsubscribe/4
]).

-export([
    publish/4,
    puback/3,
    pubrec/3,
    pubrel/3,
    pubcomp/3,
    replay/3
]).

-export([
    deliver/3,
    handle_timeout/3,
    disconnect/2,
    terminate/3
]).

% Foreign session implementations
-export([enrich_delivers/3]).

% Utilities
-export([should_keep/1]).

% Tests only
-export([get_session_conf/2]).

-export_type([
    t/0,
    conf/0,
    conninfo/0,
    reply/0,
    replies/0,
    common_timer_name/0
]).

-type session_id() :: _TODO.

-type clientinfo() :: emqx_types:clientinfo().
-type conninfo() ::
    emqx_types:conninfo()
    | #{
        %% Subset of `emqx_types:conninfo()` properties
        receive_maximum => non_neg_integer(),
        expiry_interval => non_neg_integer()
    }.

-type common_timer_name() :: retry_delivery | expire_awaiting_rel.

-type message() :: emqx_types:message().
-type publish() :: {maybe(emqx_types:packet_id()), emqx_types:message()}.
-type pubrel() :: {pubrel, emqx_types:packet_id()}.
-type reply() :: publish() | pubrel().
-type replies() :: [reply()] | reply().

-type conf() :: #{
    %% Max subscriptions allowed
    max_subscriptions := non_neg_integer() | infinity,
    %% Max inflight messages allowed
    max_inflight := non_neg_integer(),
    %% Maximum number of awaiting QoS2 messages allowed
    max_awaiting_rel := non_neg_integer() | infinity,
    %% Upgrade QoS?
    upgrade_qos := boolean(),
    %% Retry interval for redelivering QoS1/2 messages (Unit: millisecond)
    retry_interval := timeout(),
    %% Awaiting PUBREL Timeout (Unit: millisecond)
    await_rel_timeout := timeout()
}.

-type t() ::
    emqx_session_mem:session()
    | emqx_persistent_session_ds:session().

-define(INFO_KEYS, [
    id,
    created_at,
    is_persistent,
    subscriptions,
    upgrade_qos,
    retry_interval,
    await_rel_timeout
]).

-define(IMPL(S), (get_impl_mod(S))).

%%--------------------------------------------------------------------
%% Create a Session
%%--------------------------------------------------------------------

-spec create(clientinfo(), conninfo()) -> t().
create(ClientInfo, ConnInfo) ->
    Conf = get_session_conf(ClientInfo, ConnInfo),
    create(ClientInfo, ConnInfo, Conf).

create(ClientInfo, ConnInfo, Conf) ->
    % FIXME error conditions
    Session = (choose_impl_mod(ConnInfo)):create(ClientInfo, ConnInfo, Conf),
    ok = emqx_metrics:inc('session.created'),
    ok = emqx_hooks:run('session.created', [ClientInfo, info(Session)]),
    Session.

-spec open(clientinfo(), conninfo()) ->
    {_IsPresent :: true, t(), _ReplayContext} | {_IsPresent :: false, t()}.
open(ClientInfo, ConnInfo) ->
    Conf = get_session_conf(ClientInfo, ConnInfo),
    case (choose_impl_mod(ConnInfo)):open(ClientInfo, ConnInfo, Conf) of
        {_IsPresent = true, Session, ReplayContext} ->
            {true, Session, ReplayContext};
        {_IsPresent = false, NewSession} ->
            ok = emqx_metrics:inc('session.created'),
            ok = emqx_hooks:run('session.created', [ClientInfo, info(NewSession)]),
            {false, NewSession};
        _IsPresent = false ->
            {false, create(ClientInfo, ConnInfo, Conf)}
    end.

-spec get_session_conf(clientinfo(), conninfo()) -> conf().
get_session_conf(
    #{zone := Zone},
    #{receive_maximum := MaxInflight}
) ->
    #{
        max_subscriptions => get_mqtt_conf(Zone, max_subscriptions),
        max_inflight => MaxInflight,
        max_awaiting_rel => get_mqtt_conf(Zone, max_awaiting_rel),
        upgrade_qos => get_mqtt_conf(Zone, upgrade_qos),
        retry_interval => get_mqtt_conf(Zone, retry_interval),
        await_rel_timeout => get_mqtt_conf(Zone, await_rel_timeout)
    }.

get_mqtt_conf(Zone, Key) ->
    emqx_config:get_zone_conf(Zone, [mqtt, Key]).

%%--------------------------------------------------------------------
%% Existing sessions
%% -------------------------------------------------------------------

-spec destroy(clientinfo(), conninfo()) -> ok.
destroy(ClientInfo, ConnInfo) ->
    (choose_impl_mod(ConnInfo)):destroy(ClientInfo).

-spec destroy(t()) -> ok.
destroy(Session) ->
    ?IMPL(Session):destroy(Session).

%%--------------------------------------------------------------------
%% Subscriptions
%% -------------------------------------------------------------------

-spec subscribe(
    clientinfo(),
    emqx_types:topic(),
    emqx_types:subopts(),
    t()
) ->
    {ok, t()} | {error, emqx_types:reason_code()}.
subscribe(ClientInfo, TopicFilter, SubOpts, Session) ->
    SubOpts0 = ?IMPL(Session):get_subscription(TopicFilter, Session),
    case ?IMPL(Session):subscribe(TopicFilter, SubOpts, Session) of
        {ok, Session1} ->
            ok = emqx_hooks:run(
                'session.subscribed',
                [ClientInfo, TopicFilter, SubOpts#{is_new => (SubOpts0 == undefined)}]
            ),
            {ok, Session1};
        {error, RC} ->
            {error, RC}
    end.

-spec unsubscribe(
    clientinfo(),
    emqx_types:topic(),
    emqx_types:subopts(),
    t()
) ->
    {ok, t()} | {error, emqx_types:reason_code()}.
unsubscribe(
    ClientInfo,
    TopicFilter,
    UnSubOpts,
    Session
) ->
    case ?IMPL(Session):unsubscribe(TopicFilter, Session) of
        {ok, Session1, SubOpts} ->
            ok = emqx_hooks:run(
                'session.unsubscribed',
                [ClientInfo, TopicFilter, maps:merge(SubOpts, UnSubOpts)]
            ),
            {ok, Session1};
        {error, RC} ->
            {error, RC}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBLISH
%%--------------------------------------------------------------------

-spec publish(clientinfo(), emqx_types:packet_id(), emqx_types:message(), t()) ->
    {ok, emqx_types:publish_result(), t()}
    | {error, emqx_types:reason_code()}.
publish(_ClientInfo, PacketId, Msg, Session) ->
    case ?IMPL(Session):publish(PacketId, Msg, Session) of
        {ok, _Result, _Session} = Ok ->
            % TODO: only timers are allowed for now
            Ok;
        {error, RC} = Error when Msg#message.qos =:= ?QOS_2 ->
            on_dropped_qos2_msg(PacketId, Msg, RC),
            Error;
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBACK
%%--------------------------------------------------------------------

-spec puback(clientinfo(), emqx_types:packet_id(), t()) ->
    {ok, message(), replies(), t()}
    | {error, emqx_types:reason_code()}.
puback(ClientInfo, PacketId, Session) ->
    case ?IMPL(Session):puback(ClientInfo, PacketId, Session) of
        {ok, Msg, Replies, Session1} = Ok ->
            _ = on_delivery_completed(Msg, ClientInfo, Session1),
            _ = on_replies_delivery_completed(Replies, ClientInfo, Session1),
            Ok;
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREC / PUBREL / PUBCOMP
%%--------------------------------------------------------------------

-spec pubrec(clientinfo(), emqx_types:packet_id(), t()) ->
    {ok, message(), t()}
    | {error, emqx_types:reason_code()}.
pubrec(_ClientInfo, PacketId, Session) ->
    case ?IMPL(Session):pubrec(PacketId, Session) of
        {ok, _Msg, _Session} = Ok ->
            Ok;
        {error, _} = Error ->
            Error
    end.

-spec pubrel(clientinfo(), emqx_types:packet_id(), t()) ->
    {ok, t()}
    | {error, emqx_types:reason_code()}.
pubrel(_ClientInfo, PacketId, Session) ->
    case ?IMPL(Session):pubrel(PacketId, Session) of
        {ok, _Session} = Ok ->
            Ok;
        {error, _} = Error ->
            Error
    end.

-spec pubcomp(clientinfo(), emqx_types:packet_id(), t()) ->
    {ok, replies(), t()}
    | {error, emqx_types:reason_code()}.
pubcomp(ClientInfo, PacketId, Session) ->
    case ?IMPL(Session):pubcomp(ClientInfo, PacketId, Session) of
        {ok, Msg, Replies, Session1} ->
            _ = on_delivery_completed(Msg, ClientInfo, Session1),
            _ = on_replies_delivery_completed(Replies, ClientInfo, Session1),
            {ok, Replies, Session1};
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------

-spec replay(clientinfo(), _ReplayContext, t()) ->
    {ok, replies(), t()}.
replay(ClientInfo, ReplayContext, Session) ->
    ?IMPL(Session):replay(ClientInfo, ReplayContext, Session).

%%--------------------------------------------------------------------
%% Broker -> Client: Deliver
%%--------------------------------------------------------------------

-spec deliver(clientinfo(), [emqx_types:deliver()], t()) ->
    {ok, replies(), t()}.
deliver(ClientInfo, Delivers, Session) ->
    Messages = enrich_delivers(ClientInfo, Delivers, Session),
    ?IMPL(Session):deliver(ClientInfo, Messages, Session).

%%--------------------------------------------------------------------

enrich_delivers(ClientInfo, Delivers, Session) ->
    UpgradeQoS = ?IMPL(Session):info(upgrade_qos, Session),
    enrich_delivers(ClientInfo, Delivers, UpgradeQoS, Session).

enrich_delivers(_ClientInfo, [], _UpgradeQoS, _Session) ->
    [];
enrich_delivers(ClientInfo, [D | Rest], UpgradeQoS, Session) ->
    case enrich_deliver(ClientInfo, D, UpgradeQoS, Session) of
        [] ->
            enrich_delivers(ClientInfo, Rest, UpgradeQoS, Session);
        Msg ->
            [Msg | enrich_delivers(ClientInfo, Rest, UpgradeQoS, Session)]
    end.

enrich_deliver(ClientInfo, {deliver, Topic, Msg}, UpgradeQoS, Session) ->
    SubOpts = ?IMPL(Session):get_subscription(Topic, Session),
    enrich_message(ClientInfo, Msg, SubOpts, UpgradeQoS).

enrich_message(
    ClientInfo = #{clientid := ClientId},
    Msg = #message{from = ClientId},
    #{nl := 1},
    _UpgradeQoS
) ->
    _ = emqx_session_events:handle_event(ClientInfo, {dropped, Msg, no_local}),
    [];
enrich_message(_ClientInfo, MsgIn, SubOpts = #{}, UpgradeQoS) ->
    maps:fold(
        fun(SubOpt, V, Msg) -> enrich_subopts(SubOpt, V, Msg, UpgradeQoS) end,
        MsgIn,
        SubOpts
    );
enrich_message(_ClientInfo, Msg, undefined, _UpgradeQoS) ->
    Msg.

enrich_subopts(nl, 1, Msg, _) ->
    emqx_message:set_flag(nl, Msg);
enrich_subopts(nl, 0, Msg, _) ->
    Msg;
enrich_subopts(qos, SubQoS, Msg = #message{qos = PubQoS}, _UpgradeQoS = true) ->
    Msg#message{qos = max(SubQoS, PubQoS)};
enrich_subopts(qos, SubQoS, Msg = #message{qos = PubQoS}, _UpgradeQoS = false) ->
    Msg#message{qos = min(SubQoS, PubQoS)};
enrich_subopts(rap, 1, Msg, _) ->
    Msg;
enrich_subopts(rap, 0, Msg = #message{headers = #{retained := true}}, _) ->
    Msg;
enrich_subopts(rap, 0, Msg, _) ->
    emqx_message:set_flag(retain, false, Msg);
enrich_subopts(subid, SubId, Msg, _) ->
    Props = emqx_message:get_header(properties, Msg, #{}),
    emqx_message:set_header(properties, Props#{'Subscription-Identifier' => SubId}, Msg);
enrich_subopts(_Opt, _V, Msg, _) ->
    Msg.

%%--------------------------------------------------------------------
%% Timeouts
%%--------------------------------------------------------------------

-spec handle_timeout(clientinfo(), common_timer_name(), t()) ->
    {ok, replies(), t()}
    | {ok, replies(), timeout(), t()}.
handle_timeout(ClientInfo, Timer, Session) ->
    ?IMPL(Session):handle_timeout(ClientInfo, Timer, Session).

%%--------------------------------------------------------------------

-spec disconnect(clientinfo(), t()) ->
    {idle | shutdown, t()}.
disconnect(_ClientInfo, Session) ->
    ?IMPL(Session):disconnect(Session).

-spec terminate(clientinfo(), Reason :: term(), t()) ->
    ok.
terminate(ClientInfo, Reason, Session) ->
    _ = run_terminate_hooks(ClientInfo, Reason, Session),
    _ = ?IMPL(Session):terminate(Reason, Session),
    ok.

run_terminate_hooks(ClientInfo, discarded, Session) ->
    run_hook('session.discarded', [ClientInfo, info(Session)]);
run_terminate_hooks(ClientInfo, takenover, Session) ->
    run_hook('session.takenover', [ClientInfo, info(Session)]);
run_terminate_hooks(ClientInfo, Reason, Session) ->
    run_hook('session.terminated', [ClientInfo, Reason, info(Session)]).

%%--------------------------------------------------------------------
%% Session Info
%% -------------------------------------------------------------------

-spec info(t()) -> emqx_types:infos().
info(Session) ->
    maps:from_list(info(?INFO_KEYS, Session)).

-spec info
    ([atom()], t()) -> [{atom(), _Value}];
    (atom(), t()) -> _Value.
info(Keys, Session) when is_list(Keys) ->
    [{Key, info(Key, Session)} || Key <- Keys];
info(impl, Session) ->
    get_impl_mod(Session);
info(Key, Session) ->
    ?IMPL(Session):info(Key, Session).

-spec stats(t()) -> emqx_types:stats().
stats(Session) ->
    ?IMPL(Session):stats(Session).

%%--------------------------------------------------------------------
%% Common message events
%%--------------------------------------------------------------------

on_delivery_completed(Msg, #{clientid := ClientId}, Session) ->
    emqx:run_hook(
        'delivery.completed',
        [
            Msg,
            #{
                session_birth_time => ?IMPL(Session):info(created_at, Session),
                clientid => ClientId
            }
        ]
    ).

on_replies_delivery_completed(Replies, ClientInfo, Session) ->
    lists:foreach(
        fun({_PacketId, Msg}) ->
            case Msg of
                #message{qos = ?QOS_0} ->
                    on_delivery_completed(Msg, ClientInfo, Session);
                _ ->
                    ok
            end
        end,
        Replies
    ).

on_dropped_qos2_msg(PacketId, Msg, RC) ->
    ?SLOG(
        warning,
        #{
            msg => "dropped_qos2_packet",
            reason => emqx_reason_codes:name(RC),
            packet_id => PacketId
        },
        #{topic => Msg#message.topic}
    ),
    ok = emqx_metrics:inc('messages.dropped'),
    ok = emqx_hooks:run('message.dropped', [Msg, #{node => node()}, emqx_reason_codes:name(RC)]),
    ok.

%%--------------------------------------------------------------------

-spec should_keep(message() | emqx_types:deliver()) -> boolean().
should_keep(MsgDeliver) ->
    not is_banned_msg(MsgDeliver).

is_banned_msg(#message{from = ClientId}) ->
    [] =/= emqx_banned:look_up({clientid, ClientId}).

%%--------------------------------------------------------------------

-spec get_impl_mod(t()) -> module().
get_impl_mod(Session) when ?IS_SESSION_IMPL_MEM(Session) ->
    emqx_session_mem;
get_impl_mod(Session) when ?IS_SESSION_IMPL_DS(Session) ->
    emqx_persistent_session_ds.

-spec choose_impl_mod(conninfo()) -> module().
choose_impl_mod(#{expiry_interval := 0}) ->
    emqx_session_mem;
choose_impl_mod(#{expiry_interval := EI}) when EI > 0 ->
    case emqx_persistent_message:is_store_enabled() of
        true ->
            emqx_persistent_session_ds;
        false ->
            emqx_session_mem
    end.

-compile({inline, [run_hook/2]}).
run_hook(Name, Args) ->
    ok = emqx_metrics:inc(Name),
    emqx_hooks:run(Name, Args).
