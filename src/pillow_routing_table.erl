%%%---------------------------------------------------------------------
%%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%%% use this file except in compliance with the License. You may obtain a copy of
%%% the License at
%%%
%%% http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%%% License for the specific language governing permissions and limitations under
%%% the License.
%%%---------------------------------------------------------------------

-module(pillow_routing_table).
-behaviour(gen_server).

% gen_server functions
-export([init/1, start_link/0, stop/0, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-export([get_status/0]).

% Functions for general use
-export([to_list/0, get_server/1, reshard/1, flip/0]).

% Functions meant for spawning
-export([execute_reshard/2]).

-vsn(0.4).

%%--------------------------------------------------------------------
%% EXPORTED FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: start_link/0
%% Description: Starts the routing table process and links to it. 
%% Returns: {ok, Pid}
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Function: stop/0
%% Description: Stops the routing table process. Use when testing
%% from the shell
%% Returns:
%%--------------------------------------------------------------------
stop() ->
    catch gen_server:cast(?MODULE, stop).

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Callback for stop
%% Returns: ok
%%--------------------------------------------------------------------
terminate(_Reason, _RoutingTable) ->
    ok.
    
%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Creates and returns a new routing table
%% Returns: {ok, RoutingTable}
%%--------------------------------------------------------------------
init(_) ->
    pillow_monitor:add_status(pillow_reshard_status, ok),
    set_routing_table(couch_config:get("routing", "routing_table"), true).

%%--------------------------------------------------------------------
%% Function: to_list/0
%% Description: Creates a list of the values in Dict
%% Returns: A list with values from Dict
%%--------------------------------------------------------------------
to_list() ->
    gen_server:call(?MODULE, to_list).

%%--------------------------------------------------------------------
%% Function: get_server/1
%% Description: Retrieves the right server for the Db, Id pair
%% Returns: A server url
%%--------------------------------------------------------------------
get_server(Id) ->
    gen_server:call(?MODULE, {get_server, Id}).

%%--------------------------------------------------------------------
%% Function: reshard/1
%% Description: Currently sets up validation filters for resharding the databases
%% Returns: ok
%%--------------------------------------------------------------------
reshard(AutoFlip) ->
    gen_server:cast(?MODULE, {reshard, AutoFlip}).

%%--------------------------------------------------------------------
%% Function: flip/0
%% Description: Flips from using old routing table to the new one. Also updates
%%     the config file
%% Returns: ok
%%--------------------------------------------------------------------
flip() ->
    gen_server:call(?MODULE, flip).

%%--------------------------------------------------------------------
%% Function: get_status/0
%% Description: Toggles the resharding in progress flag
%% Returns: {CurrentRoutingTableAsList, NewRoutingTableAsList, Databases}
%%--------------------------------------------------------------------
get_status() ->
    gen_server:call(?MODULE, status).

%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handler for gen_server:call
%% Returns: {reply, Message, RoutingTable}
%%--------------------------------------------------------------------
handle_call({get_server, Id}, _From, RoutingTable) ->
    {reply, get_routing(Id, RoutingTable), RoutingTable};
handle_call(to_list, _From, RoutingTable) ->
    {reply, dict:to_list(RoutingTable), RoutingTable};
handle_call(flip, _From, RoutingTable) ->
    {ok, NewRoutingTable} = execute_flip(RoutingTable),
    {reply, ok, NewRoutingTable};
handle_call({set_routing_table, NewRoutingTable}, _From, _RoutingTable) ->
    {ok, RoutingTable} = set_routing_table(NewRoutingTable, true),
    {reply, ok, RoutingTable};
handle_call(status, _From, RoutingTable) ->
    {ok, NewRoutingTable} = safely_get_resharding_routing_table(false),
    {reply, {dict:to_list(RoutingTable), dict:to_list(NewRoutingTable), get_databases()}, RoutingTable}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handler for gen_server:cast
%% Returns: {stop, normal, RoutingTable}
%%--------------------------------------------------------------------
handle_cast({reshard, AutoFlip}, RoutingTable) ->
    spawn(?MODULE, execute_reshard, [RoutingTable, AutoFlip]),
    {noreply, RoutingTable};
handle_cast(stop, RoutingTable) ->
    {stop, normal, RoutingTable}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handler for unknown messages
%% Returns: {noreply, RoutingTable}
%%--------------------------------------------------------------------
handle_info(Info, RoutingTable) ->
    io:format("~s got unknown message: ~w~n", [?MODULE, Info]),
    {noreply, RoutingTable}.

%%--------------------------------------------------------------------
%% Function: code_change/3
%% Description: Callback for release upgrade/downgrade
%% Returns: {ok, RoutingTable}
%%--------------------------------------------------------------------
code_change(_OldVsn, _RoutingTable, _Extra) ->
    {ok, set_routing_table(couch_config:get("routing", "routing_table"), true)}.

%%--------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: get_shard_validator/2
%% Description: Creates a javascript shard validator for the given shard number
%% Returns: The new validator in a string
%%--------------------------------------------------------------------
get_shard_validator(Shard, NumShards) ->
    "function(doc, oldDoc, userCtx) {"
    ++ "  var myShardNumber = "
    ++ "  " ++ integer_to_list(Shard) ++ ";"
    ++ "  var shard = 0;"
    ++ "  for (var i = 0; i < doc._id.length; ++i) {"
    ++ "    shard += doc._id.charCodeAt(i);"
    ++ "  }"
    ++ "  shard = (shard % " ++ integer_to_list(NumShards) ++ ") + 1;"
    ++ "  if (shard != myShardNumber) throw({forbidden: 'wrong hash'});"
    ++ "}".

%%--------------------------------------------------------------------
%% Function: store_validator/2
%% Description: Stores Validator in Url
%% Returns: ibrowse response
%%--------------------------------------------------------------------
store_validator(Validator, Url) ->
    io:format("put ~s~n", [Url]),
    {ok, "201", _Headers, Response} = ibrowse:send_req(Url, [], put, ""),
    io:format("~w~n", [Response]),
    DesignDoc = mochijson2:encode(
        {struct, [
            {<<"_id">>, <<"_design/shard">>},
            {<<"validate_doc_update">>, list_to_binary(Validator)}
        ]}),
    io:format("~s: ~s~n", [Url, DesignDoc]),
    ibrowse:send_req(Url, [], post, DesignDoc).
%    {ok, "201", "Headers", "Response"}.


%%--------------------------------------------------------------------
%% Function: create_shard_validator/2
%% Description: creates sharding validators for the given shard and the rest of the Dict
%% Returns: ok or error
%%--------------------------------------------------------------------
create_shard_validator(Db, Shard, Dict) ->
    NumShards = dict:size(Dict),
    Validator = get_shard_validator(Shard, NumShards),
    Result = case dict:find(Shard, Dict) of
        {ok, Url} -> store_validator(Validator, Url ++ Db);
        _ -> error
    end,
    case Result of
        {ok, "201", _Headers, _Response} ->
            case NumShards of
                Shard -> ok;
                _ -> create_shard_validator(Db, Shard + 1, Dict)
            end;
        _ -> error
    end.

%%--------------------------------------------------------------------
%% Function: create_shard_validators/2
%% Description: creates sharding validators for Db for all servers in Dict
%% Returns: ok or error
%%--------------------------------------------------------------------
create_shard_validators(Db, Dict) ->
    create_shard_validator(Db, 1, Dict).

%%--------------------------------------------------------------------
%% Function: init_replication/4
%% Description: Sets up a pull replication
%% Returns: The ibrowse response
%%--------------------------------------------------------------------
init_replication(Db, Source, Target, Continuous) ->
    Url = Source ++ "_replicate",
    TargetDb = Target ++ Db,
    io:format("init_replication from ~s/~s to ~s~n", [Source, Db, TargetDb]),
    ReplicationDefinition = [
        {<<"source">>, list_to_binary(Db)},
        {<<"target">>, list_to_binary(TargetDb)}
    ],
    ReplicationSpecification = case Continuous of
        true -> lists:flatten(ReplicationDefinition, [{<<"continuous">>, Continuous}]);
        _ -> ReplicationDefinition
    end,
    Message = mochijson2:encode({struct, ReplicationSpecification}),
    io:format("~s: ~s~n", [Url, Message]),
    ibrowse:send_req(Url, [], post, Message).
%    Status = case Continuous of
%        true -> "202";
%        _ -> "200"
%    end,
%    {ok, Status, "Headers", "Response"}.

%%--------------------------------------------------------------------
%% Function: init_all_replication/6
%% Description: Sets up a continuous push replication for all shards
%% Returns: ok or error depending on result
%%--------------------------------------------------------------------
init_all_replication(Db, SourceShard, TargetShard, SourceDict, TargetDict, Continuous) ->
    Status = case Continuous of
        true -> "202";
        _ -> "200"
    end,
    CurrentResult = case dict:find(SourceShard, SourceDict) of
        {ok, SourceUrl} ->
            case dict:find(TargetShard, TargetDict) of
                {ok, TargetUrl} -> init_replication(Db, SourceUrl, TargetUrl, Continuous);
                _ ->
                    io:format("Tried to find ~i of ~i target shards", [TargetShard, dict:size(TargetDict)]),
                    error
            end;
        _ ->
            io:format("Tried to find ~i of ~i source shards", [SourceShard, dict:size(SourceDict)]),
            error
    end,
    NextResult = case CurrentResult of
        {ok, Status, _Headers1, _Response1} ->
            case dict:size(TargetDict) of
                TargetShard -> ok;
                _ -> init_all_replication(Db, SourceShard, TargetShard + 1, SourceDict, TargetDict, Continuous)
            end
    end,
    case NextResult of
        ok ->
            case dict:size(SourceDict) of
                SourceShard -> ok;
                _ -> init_all_replication(Db, SourceShard + 1, TargetShard, SourceDict, TargetDict, Continuous)
            end
    end.

%%--------------------------------------------------------------------
%% Function: init_all_databases_replication/3
%% Description: Initiates replication for all databases
%% Returns: ok or error depending on result
%%--------------------------------------------------------------------
init_all_databases_replication([], _, _, _) -> ok;
init_all_databases_replication([Db | Tail], RoutingTable, NewRoutingTable, Continuous) ->
    io:format("Setting up replication of ~s~n", [Db]),
    init_all_replication(Db, 1, 1, RoutingTable, NewRoutingTable, Continuous),
    init_all_databases_replication(Tail, RoutingTable, NewRoutingTable, Continuous).

%%--------------------------------------------------------------------
%% Function: create_all_databases_shard_validators/3
%% Description: Initiates replication for all databases
%% Returns: ok or error depending on result
%%--------------------------------------------------------------------
create_all_databases_shard_validators([], _) -> ok;
create_all_databases_shard_validators([Db | Tail], NewRoutingTable) ->
    io:format("Creating shard validator for ~s~n", [Db]),
    create_shard_validators(Db, NewRoutingTable),
    create_all_databases_shard_validators(Tail, NewRoutingTable).

%%--------------------------------------------------------------------
%% Function: get_resharding_routing_table/1
%% Description: Gets the config stating the new routing Table
%% Returns: ok or error depending on result
%%--------------------------------------------------------------------
get_resharding_routing_table(LogInfo) ->
    set_routing_table(couch_config:get("resharding", "routing_table"), LogInfo).

%%--------------------------------------------------------------------
%% Function: safely_get_resharding_routing_table/1
%% Description: Same as above, but doesn't fail if not found
%% Returns: The resharding routing table or an empty dict
%%--------------------------------------------------------------------
safely_get_resharding_routing_table(LogInfo) ->
    case couch_config:get("resharding", "routing_table") of
        undefined -> {ok, dict:new()};
        List -> set_routing_table(List, LogInfo)
    end.

%%--------------------------------------------------------------------
%% Function: execute_reshard/2
%% Description: Starts replication to new resharding servers
%% Returns: ok or error depending on result
%%--------------------------------------------------------------------
execute_reshard(RoutingTable, AutoFlip) ->
    pillow_monitor:update_status(pillow_reshard_status, resharding),
    {ok, NewRoutingTable} = get_resharding_routing_table(true),
    create_all_databases_shard_validators(get_databases(), NewRoutingTable),
    init_all_databases_replication(get_databases(), RoutingTable, NewRoutingTable, false),
    init_all_databases_replication(get_databases(), RoutingTable, NewRoutingTable, true),
    case AutoFlip of
        true -> flip();
        _ -> pillow_monitor:update_status(pillow_reshard_status, ready)
    end.

%%--------------------------------------------------------------------
%% Function: execute_flip/1
%% Description: Flips from using old routing table to the new one. Also updates
%%     the config file
%% Returns: {ok, NewRoutingTable} or {error, RoutingTable}
%%--------------------------------------------------------------------
execute_flip(RoutingTable) ->
    pillow_monitor:update_status(pillow_reshard_status, flipping),
    Result = case set_routing_table(couch_config:get("resharding", "routing_table"), true) of
        {ok, NewRoutingTable} ->
            ok = couch_config:set("old_routing", "routing_table", couch_config:get("routing", "routing_table"), true),
            ok = couch_config:set("routing", "routing_table", couch_config:get("resharding", "routing_table"), true),
            ok = couch_config:delete("resharding", "routing_table", true),
            {ok, NewRoutingTable};
        _ -> {error, RoutingTable}
    end,
    {Status, _RoutingTable} = Result,
    pillow_monitor:update_status(pillow_reshard_status, Status),
    Result.

%%--------------------------------------------------------------------
%% Function: get_routing/2
%% Description: Retrieves the server for Id from Dict
%% Returns: The server URL as a string
%%--------------------------------------------------------------------
get_routing(Id, Dict) ->
    Key = lists:sum(Id) rem dict:size(Dict) + 1,
    io:format("Shard: ~i for ~s~n", [Key, Id]),
    dict:fetch(Key, Dict).

%%--------------------------------------------------------------------
%% Function: set_routing/4
%% Description: Adds the new route to the routing table
%% Returns: The updated routing table
%%--------------------------------------------------------------------
set_routing(_NextNum, [], Dict, _LogInfo) -> Dict;
set_routing(NextNum, [Head|Tail], OldDict, LogInfo) ->
    case LogInfo of
        true -> io:format("Route shard: ~B -> ~s~n", [NextNum, Head]);
        _ -> ok
    end,
    NewDict = dict:store(NextNum, Head, OldDict),
    set_routing(NextNum + 1, Tail, NewDict, LogInfo).

%%--------------------------------------------------------------------
%% Function: set_routing_table/2
%% Description: Purges and reloads the routing table
%% Returns: {upgrade, PreVersion, PostVersion}
%%--------------------------------------------------------------------
set_routing_table(NewRoutingTable, LogInfo) ->
    FullTable = set_routing(1, re:split(NewRoutingTable, " *, *", [{return, list}]), dict:new(), LogInfo),
    {ok, FullTable}.

%%--------------------------------------------------------------------
%% Function: get_databases/0
%% Description: Returns the names of the databases controlled by Pillow
%% Returns: A list of db names
%%--------------------------------------------------------------------
get_databases() ->
    re:split(couch_config:get("pillow", "databases"), ",", [{return, list}]).
