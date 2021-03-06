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

%%%---------------------------------------------------------------------
%%% Callbacks for the Pillow application.
%%%---------------------------------------------------------------------

-module(pillow_app).
-behaviour(application).

-export([start/2,stop/1]).

%%--------------------------------------------------------------------
%% EXPORTED FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: start/2
%% Description: application start callback for Pillow.
%% Returns: ServerRet
%%--------------------------------------------------------------------
start(_Type, DefaultIniFiles) ->
    IniFiles = case init:get_argument(pillow_ini) of
        error -> DefaultIniFiles;
        {ok, [[]]} -> DefaultIniFiles;
        {ok, [Values]} -> Values;
        _ -> io:format("Odd error")
    end,
    pillow_sup:start_link(IniFiles).

%%--------------------------------------------------------------------
%% Function: stop/1
%% Description: application stop callback for Pillow.
%% Returns: ServerRet
%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%--------------------------------------------------------------------
%% INTERNAL FUNCTIONS
%%--------------------------------------------------------------------
