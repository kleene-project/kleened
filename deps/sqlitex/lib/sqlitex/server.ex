defmodule Sqlitex.Server do
  @moduledoc """
  Sqlitex.Server provides a GenServer to wrap a sqlitedb.
  This makes it easy to share a SQLite database between multiple processes without worrying about concurrency issues.
  You can also register the process with a name so you can query by name later.

  ## Unsupervised Example
  ```
  iex> {:ok, pid} = Sqlitex.Server.start_link(":memory:", [name: :example])
  iex> Sqlitex.Server.exec(pid, "CREATE TABLE t (a INTEGER, b INTEGER)")
  :ok
  iex> Sqlitex.Server.exec(pid, "INSERT INTO t (a, b) VALUES (1, 1), (2, 2), (3, 3)")
  :ok
  iex> Sqlitex.Server.query(pid, "SELECT * FROM t WHERE b = 2")
  {:ok, [[a: 2, b: 2]]}
  iex> Sqlitex.Server.query(:example, "SELECT * FROM t ORDER BY a LIMIT 1", into: %{})
  {:ok, [%{a: 1, b: 1}]}
  iex> Sqlitex.Server.query_rows(:example, "SELECT * FROM t ORDER BY a LIMIT 2")
  {:ok, %{rows: [[1, 1], [2, 2]], columns: [:a, :b], types: [:INTEGER, :INTEGER]}}
  iex> Sqlitex.Server.prepare(:example, "SELECT * FROM t")
  {:ok, %{columns: [:a, :b], types: [:INTEGER, :INTEGER]}}
    # Subsequent queries using this exact statement will now operate more efficiently
    # because this statement has been cached.
  iex> Sqlitex.Server.prepare(:example, "INVALID SQL")
  {:error, {:sqlite_error, 'near "INVALID": syntax error'}}
  iex> Sqlitex.Server.stop(:example)
  :ok
  iex> :timer.sleep(10) # wait for the process to exit asynchronously
  iex> Process.alive?(pid)
  false

  ```

  ## Supervised Example
  ```
  import Supervisor.Spec

  children = [
    worker(Sqlitex.Server, ["priv/my_db.sqlite3", [name: :my_db])
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
  ```
  """

  use GenServer

  alias Sqlitex.Config
  alias Sqlitex.Server.StatementCache, as: Cache
  alias Sqlitex.Statement

  @doc """
  Starts a SQLite Server (GenServer) instance.

  In addition to the options that are typically provided to `GenServer.start_link/3`,
  you can also specify:

  - `stmt_cache_size: (positive_integer)` to override the default limit (20) of statements
    that are cached when calling `prepare/3`.
  - `db_timeout: (positive_integer)` to override `:esqlite3`'s default timeout of 5000 ms for
    interactions with the database. This can also be set in `config.exs` as `config :sqlitex, db_timeout: 5_000`.
  - `db_chunk_size: (positive_integer)` to override `:esqlite3`'s default chunk_size of 5000 rows
    to read from native sqlite and send to erlang process in one bulk.
    This can also be set in `config.exs` as `config :sqlitex, db_chunk_size: 5_000`.
  """
  def start_link(db_path, opts \\ []) do
    stmt_cache_size = Keyword.get(opts, :stmt_cache_size, 20)
    config = [
      db_timeout: Config.db_timeout(opts),
      db_chunk_size: Config.db_chunk_size(opts)
    ]
    GenServer.start_link(__MODULE__, {db_path, stmt_cache_size, config}, opts)
  end

  ## GenServer callbacks

  def init({db_path, stmt_cache_size, config})
    when is_integer(stmt_cache_size) and stmt_cache_size > 0
  do
    case Sqlitex.open(db_path, config) do
      {:ok, db} -> {:ok, {db, __MODULE__.StatementCache.new(db, stmt_cache_size), config}}
      {:error, reason} -> {:stop, reason}
    end
  end

  def handle_call({:exec, sql}, _from, {db, stmt_cache, config}) do
    result = Sqlitex.exec(db, sql, config)
    {:reply, result, {db, stmt_cache, config}}
  end

  def handle_call({:query, sql, opts}, _from, {db, stmt_cache, config}) do
    case query_impl(sql, stmt_cache, Keyword.merge(config, opts)) do
      {:ok, result, new_cache} -> {:reply, {:ok, result}, {db, new_cache, config}}
      err -> {:reply, err, {db, stmt_cache, config}}
    end
  end

  def handle_call({:query_rows, sql, opts}, _from, {db, stmt_cache, config}) do
    case query_rows_impl(sql, stmt_cache, Keyword.merge(config, opts)) do
      {:ok, result, new_cache} -> {:reply, {:ok, result}, {db, new_cache, config}}
      err -> {:reply, err, {db, stmt_cache, config}}
    end
  end

  def handle_call({:prepare, sql}, _from, {db, stmt_cache, config}) do
    case prepare_impl(sql, stmt_cache, config) do
      {:ok, result, new_cache} -> {:reply, {:ok, result}, {db, new_cache, config}}
      err -> {:reply, err, {db, stmt_cache, config}}
    end
  end

  def handle_call({:create_table, name, table_opts, cols}, _from, {db, stmt_cache, config}) do
    result = Sqlitex.create_table(db, name, table_opts, cols, config)
    {:reply, result, {db, stmt_cache, config}}
  end

  def handle_call({:set_update_hook, pid, opts}, _from, {db, stmt_cache, config}) do
    result = Sqlitex.set_update_hook(db, pid, Keyword.merge(config, opts))
    {:reply, result, {db, stmt_cache, config}}
  end

  def handle_cast(:stop, {db, stmt_cache, config}) do
    {:stop, :normal, {db, stmt_cache, config}}
  end

  def terminate(_reason, {db, _stmt_cache, config}) do
    Sqlitex.close(db, config)
    :ok
  end

  ## Public API

  @doc """
  Same as `Sqlitex.exec/3` but using the shared db connections saved in the GenServer state.

  Returns the results otherwise.
  """
  def exec(pid, sql, opts \\ []) do
    GenServer.call(pid, {:exec, sql}, Config.call_timeout(opts))
  end

  @doc """
  Same as `Sqlitex.Query.query/3` but using the shared db connections saved in the GenServer state.

  Returns the results otherwise.
  """
  def query(pid, sql, opts \\ []) do
    GenServer.call(pid, {:query, sql, opts}, Config.call_timeout(opts))
  end

  @doc """
  Same as `Sqlitex.Query.query_rows/3` but using the shared db connections saved in the GenServer state.

  Returns the results otherwise.
  """
  def query_rows(pid, sql, opts \\ []) do
    GenServer.call(pid, {:query_rows, sql, opts}, Config.call_timeout(opts))
  end

  def set_update_hook(server_pid, notification_pid, opts \\ []) do
    GenServer.call(server_pid, {:set_update_hook, notification_pid, opts}, Config.call_timeout(opts))
  end

  @doc """
  Prepares a SQL statement for future use.

  This causes a call to [`sqlite3_prepare_v2`](https://sqlite.org/c3ref/prepare.html)
  to be executed in the Server process. To protect the reference to the corresponding
  [`sqlite3_stmt` struct](https://sqlite.org/c3ref/stmt.html) from misuse in other
  processes, that reference is not passed back. Instead, prepared statements are
  cached in the Server process. If a subsequent call to `query/3` or `query_rows/3`
  is made with a matching SQL statement, the prepared statement is reused.

  Prepared statements are purged from the cache when the cache exceeds a preset
  limit (20 statements by default).

  Returns summary information about the prepared statement.
  `{:ok, %{columns: [:column1_name, :column2_name,... ], types: [:column1_type, ...]}}`
  on success or `{:error, {:reason_code, 'SQLite message'}}` if the statement
  could not be prepared.
  """
  def prepare(pid, sql, opts \\ []) do
    GenServer.call(pid, {:prepare, sql}, Config.call_timeout(opts))
  end

  def create_table(pid, name, table_opts \\ [], cols) do
    GenServer.call(pid, {:create_table, name, table_opts, cols})
  end

  def stop(pid) do
    GenServer.cast(pid, :stop)
  end

  ## Helpers

  defp query_impl(sql, stmt_cache, opts) do
    with {%Cache{} = new_cache, stmt} <- Cache.prepare(stmt_cache, sql, opts),
         {:ok, stmt} <- Statement.bind_values(stmt, Keyword.get(opts, :bind, []), opts),
         {:ok, rows} <- Statement.fetch_all(stmt, opts),
    do: {:ok, rows, new_cache}
  end

  defp query_rows_impl(sql, stmt_cache, opts) do
    with {%Cache{} = new_cache, stmt} <- Cache.prepare(stmt_cache, sql, opts),
         {:ok, stmt} <- Statement.bind_values(stmt, Keyword.get(opts, :bind, []), opts),
         {:ok, rows} <- Statement.fetch_all(stmt, Keyword.put(opts, :into, :raw_list)),
    do: {:ok,
         %{rows: rows, columns: stmt.column_names, types: stmt.column_types},
         new_cache}
  end

  defp prepare_impl(sql, stmt_cache, opts) do
    with {%Cache{} = new_cache, stmt} <- Cache.prepare(stmt_cache, sql, opts),
    do: {:ok, %{columns: stmt.column_names, types: stmt.column_types}, new_cache}
  end
end
