%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at fusedsolutions dot com>
%%

%% @doc Some common helper funtions for implementing web_api in modules.

-export([web_api/2]).

-type(http_response_code() :: pos_integer()).
-type(http_headers() :: [string()]).
-type(http_body() :: string()).
-spec(web_api/2 :: (Path :: string(), Post :: [{string(), string()}]) -> {http_response_code(), http_headers(), http_body()}).

-define(json(Struct), mochiweb2:json_encode(Struct)).
-define(reply_err(Message), {200, [], ?json({struct, [{success, false}, {message, Message}]})}).
-define(reply_success(Struct), {200, [], ?json({struct, [{success, true}, {result, Struct}]})}).