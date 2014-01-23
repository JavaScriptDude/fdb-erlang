-module(fdb).
-export([init/0,init/1]).
-export([api_version/1,open/0]).
-export([get/2,get/3,set/3]).
-export([clear/2]).
-export([transact/2]).
-export([bind/2,next/1]).

-define (FDB_API_VERSION, 21).

-define (FUTURE_TIMEOUT, 5000).
-include("../include/fdb.hrl").

-type fdb_version() :: pos_integer().
-type fdb_errorcode() :: pos_integer().
-type fdb_cmd_result() :: ok | {error, fdb_errorcode()}.
%-type fdb_qry_result() :: {ok, term()} | {error, fdb_errorcode()}.
-type fdb_database() :: {db, term()}.
-type fdb_transaction() :: {tx, term()}.
-type fdb_handle() :: fdb_database() | fdb_transaction().
-type fdb_key() :: binary().

%% @doc Loads the native FoundationDB library file from a certain location
-spec init(SoFile::list())-> ok | {error, term()}.
%% @end
init(SoFile) -> fdb_nif:init(SoFile).

%% @doc Loads the native FoundationDB library file from  `priv/fdb_nif.so`
-spec init()-> ok | {error, term()}.
%% @end
init() ->
  init("priv/fdb_nif").

%% @doc Specify the API version we are using
%%
%% This function must be called after the init, and before any other function in
%% this library is called.
-spec api_version(fdb_version()) -> fdb_cmd_result().
%% @end
api_version(Version) ->
  handle_fdb_result(fdb_nif:fdb_select_api_version(Version)).

%% @doc  Opens the given database 
%% 
%% (or the default database of the cluster indicated by the fdb.cluster file in a 
%% platform-specific location, if no cluster_file or database_name is provided).  
%% Initializes the FDB interface as required.
-spec open() -> fdb_database().
%% @end
open() ->
  fdb_nif:fdb_setup_network(),
  fdb_nif:fdb_run_network(),
  ClusterF = fdb_nif:fdb_create_cluster(),
  {ok, ClusterHandle} =  future_get(ClusterF, cluster),
  DatabaseF =  fdb_nif:fdb_cluster_create_database(ClusterHandle),
  DBR = future_get(DatabaseF, database),
  {ok, DbHandle} = DBR, 
  {ok,{db, DbHandle}}.

%% @doc Gets a value using a key or multiple values using a selector
%%
%% Returns `not_found` for the single value if the key is not found, 
-spec get(fdb_handle(), fdb_key()|#select{}) -> (term() | not_found).
%% @end
get({db, DB}, Select = #select{}) ->
  transact(DB, fun(Tx) -> get(Tx, Select) end);
get({tx, Tx}, Select = #select{}) ->
  Iterator = bind(Tx, Select),
  Next = next(Iterator),
  Next#iterator.data;
get(FdbHandle, Key) -> 
  get(FdbHandle, Key, not_found).

%% @doc Gets a value using a key, falls back to a default value if not found
-spec get(fdb_handle(), fdb_key(), term()) -> term().
%% @end
get(DB={db, _Database}, Key, DefaultValue) ->
  transact(DB, fun(Tx) -> get(Tx, Key, DefaultValue) end);
get({tx, Tx}, Key, DefaultValue) ->
  GetF = fdb_nif:fdb_transaction_get(Tx, tuple:pack(Key)),
  {ok, Result} = future_get(GetF, value),
  case Result of
    not_found -> DefaultValue;
    _ -> Result
  end.

bind({db, DB}, Select = #select{}) ->
  transact(DB, fun(Tx) -> get(Tx, Select) end);
bind({tx, Transaction}, Select = #select{}) ->
  #iterator{tx = Transaction, select = Select, iteration = Select#select.iteration}.

next(Iterator = #iterator{tx = Transaction, data = OldData, iteration = Iteration, select = Select}) 
  when Iteration == 0 orelse OldData =/= [] ->
  {FstKey, FstIsEq} = extract_keys(Select#select.gt, Select#select.gte,<<0>>),
  {LstKey, LstIsEq} = extract_keys(Select#select.lt, Select#select.lte,<<255,255,255,255>>),
  F = fdb_nif:fdb_transaction_get_range(Transaction, 
    FstKey, FstIsEq, Select#select.offset_begin,
    LstKey, LstIsEq, Select#select.offset_end,
    Select#select.limit, 
    Select#select.target_bytes, 
    Select#select.streaming_mode, 
    Iteration, 
    Select#select.is_snapshot, 
    Select#select.is_reverse),
  {ok, Data} = fdb_nif:future_get(F, keyvalue_array),
  Iterator#iterator{ data = Data, iteration = Iteration + 1}.

extract_keys(nil, nil, Default) -> {Default, true};
extract_keys(nil, Value, _) -> { tuple:pack(Value), true };
extract_keys(Value, nil, _) -> { tuple:pack(Value), false }.

%% @doc sets a key and value
%% Existing values will be overwritten
-spec set(fdb_handle(), fdb_key(), term()) -> fdb_cmd_result().
%% @end
set({db, Database}, Key, Value) ->
  transact({db, Database}, fun (Tx)-> set(Tx, Key, Value) end);
set({tx, Tx}, Key, Value) ->
  ErrCode = fdb_nif:fdb_transaction_set(Tx, tuple:pack(Key), Value),
  handle_fdb_result(ErrCode).

%% @doc Clears a key and it's value
-spec clear(fdb_handle(), fdb_key()) -> fdb_cmd_result().
%% @end
clear({db, Database}, Key) ->
  transact({db, Database}, fun (Tx)-> clear(Tx, Key) end);
clear({tx, Tx}, Key) ->
  ErrCode = fdb_nif:fdb_transaction_clear(Tx, tuple:pack(Key)),
  handle_fdb_result(ErrCode).

transact({db, DbHandle}, DoStuff) ->
  CommitResult = attempt_transaction(DbHandle, DoStuff),
  handle_transaction_attempt(CommitResult).

attempt_transaction(DbHandle, DoStuff) ->
  {0, Tx} = fdb_nif:fdb_database_create_transaction(DbHandle),
  Result = DoStuff({tx, Tx}),
  ApplySelf = fun() -> attempt_transaction(DbHandle, DoStuff) end,
  CommitF = fdb_nif:fdb_transaction_commit(Tx), 
  {future(CommitF), Tx, Result, ApplySelf}.

handle_transaction_attempt({ok, _Tx, Result, _ApplySelf}) -> Result;
handle_transaction_attempt({{error, Err}, Tx, _Result, ApplySelf}) ->
  OnErrorF = fdb_nif:fdb_transaction_on_error(Tx, Err),
  RetryAllowed = future(OnErrorF),
  maybe_reattempt_transaction(RetryAllowed, ApplySelf).

maybe_reattempt_transaction(ok, ApplySelf) ->  ApplySelf();
maybe_reattempt_transaction(Error, _ApplySelf) -> Error.

handle_fdb_result({0, RetVal}) -> {ok, RetVal};
handle_fdb_result({FdbErrorcode, _RetVal}) -> {error, FdbErrorcode};
handle_fdb_result(0) -> ok;
handle_fdb_result(FdbErrorcode) -> {error, FdbErrorcode}.

future(F) -> future_get(F, none).

future_get(F, FQuery) -> 
  FullQuery = list_to_atom("fdb_future_get_" ++ atom_to_list(FQuery)),
  ok = wait_non_blocking(F, fdb_nif:fdb_future_is_ready(F)),
  ErrCode = 0, %% no longer needed
  check_future_error(ErrCode, F, FullQuery).

wait_non_blocking(F, false) ->
  Ref = make_ref(),
  0 = fdb_nif:send_on_complete(F,self(),Ref),
  receive
    Ref -> ok
    after ?FUTURE_TIMEOUT -> timeout
  end;
wait_non_blocking(_F, true) ->
  ok.

check_future_error(0, F, FQuery) ->
  ErrCode = fdb_nif:fdb_future_get_error(F),
  maybe_get_future_value(ErrCode, F, FQuery);
check_future_error(ErrCode, _F, _FQuery) -> handle_fdb_result(ErrCode).

maybe_get_future_value(0, _F, fdb_future_get_none) ->
  ok;
maybe_get_future_value(0, F, FQuery) ->
  handle_fdb_result(apply(fdb_nif, FQuery, [F]));
maybe_get_future_value(ErrCode, _F, _FQuery) -> 
  handle_fdb_result(ErrCode).
