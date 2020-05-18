defmodule Jocker.Engine.MetaData do
  require Logger
  alias Jocker.Engine.Config
  require Config
  import Jocker.Engine.Records

  use Agent

  @table_layers """
  CREATE TABLE IF NOT EXISTS
  layers (
    id         TEXT PRIMARY KEY,
    parent_id  TEXT,
    dataset    TEXT,
    snapshot   TEXT,
    mountpoint TEXT
  )
  """

  @table_images """
  CREATE TABLE IF NOT EXISTS
  images (
    id       TEXT PRIMARY KEY,
    name     TEXT,
    tag      TEXT, -- {String.t(), String.t()},
    layer_id TEXT,
    command  TEXT, --[string]
    user     TEXT,
    created  TEXT
  )
  """

  @table_containers """
  CREATE TABLE IF NOT EXISTS
  containers (
    id       TEXT PRIMARY KEY,
    name     TEXT,
    running  INTEGER,
    pid      TEXT,
    command  TEXT, --[string]
    layer_id TEXT,
    ip       TEXT,
    image_id TEXT,
    parameters TEXT, --[string]
    created  TEXT
    )
  """
  @type list_containers_opts :: [
          {:all, boolean()}
        ]

  @type db_opts() :: [
          {:file, String.t()}
        ]

  @type jocker_record() ::
          Jocker.Engine.Records.layer()
          | Jocker.Engine.Records.container()
          | Jocker.Engine.Records.image()

  @type record_type() :: :image | :layer | :container

  @spec start_link(db_opts()) :: Agent.on_start()
  def start_link(opts) do
    filepath = Keyword.get(opts, :file)
    {:ok, db} = Sqlitex.open(filepath)
    create_tables(db)
    Agent.start_link(fn -> db end, name: __MODULE__)
  end

  def stop() do
    Agent.stop(__MODULE__)
  end

  @spec add_layer(Jocker.Engine.Records.layer()) :: :ok
  def add_layer(layer) do
    Agent.update(__MODULE__, fn db -> add_layer_(db, layer) end)
  end

  @spec get_layer(String.t()) :: Jocker.Engine.Records.layer() | :not_found
  def get_layer(layer_id) do
    Agent.get(__MODULE__, fn db -> get_layer_(db, layer_id) end)
  end

  @spec add_image(Jocker.Engine.Records.image()) :: :ok
  def add_image(image) do
    Agent.update(__MODULE__, fn db -> add_image_(db, image) end)
  end

  @spec get_image(String.t()) :: Jocker.Engine.Records.image() | :not_found
  def get_image(id_or_nametag) do
    Agent.get(__MODULE__, fn db -> get_image_(db, id_or_nametag) end)
  end

  @spec list_images() :: [Jocker.Engine.Records.image()]
  def list_images() do
    Agent.get(__MODULE__, fn db -> list_images_(db) end)
  end

  @spec add_container(Jocker.Engine.Records.container()) :: :ok
  def add_container(container) do
    Agent.update(__MODULE__, fn db -> add_container_(db, container) end)
  end

  @spec get_container(String.t()) :: Jocker.Engine.Records.container() | :not_found
  def get_container(id_or_name) do
    Agent.get(__MODULE__, fn db -> get_container_(db, id_or_name) end)
  end

  @spec list_containers(list_containers_opts()) :: [Jocker.Engine.Records.container()]
  def list_containers(opts \\ []) do
    Agent.get(__MODULE__, fn db -> list_containers_(db, opts) end)
  end

  @spec clear_tables() :: :ok
  def clear_tables() do
    Agent.update(__MODULE__, fn db -> clear_tables_(db) end)
  end

  ##########################
  ### Internal functions ###
  ##########################
  def add_layer_(db, layer) do
    row = record2row(layer)
    :ok = exec(db, "INSERT OR REPLACE INTO layers VALUES (?, ?, ?, ?, ?)", row)
    db
  end

  def get_layer_(db, layer_id) do
    case fetch_all(db, "SELECT * FROM layers WHERE id=?", [layer_id]) do
      {:ok, [row]} -> row2record(:layer, row)
      {:ok, []} -> :not_found
    end
  end

  def add_image_(db, image(name: new_name, tag: new_tag) = image) do
    result =
      fetch_all(
        db,
        "SELECT * FROM images WHERE name != '' AND tag != '' AND name = ? AND tag = ?",
        [new_name, new_tag]
      )

    case result do
      {:ok, []} ->
        :ok

      {:ok, [row]} ->
        img = row2record(:image, row)
        existing_image = image(img, name: "", tag: "")
        row = record2row(existing_image)
        :ok = exec(db, "INSERT OR REPLACE INTO images VALUES (?, ?, ?, ?, ?, ? ,?)", row)
    end

    row = record2row(image)
    :ok = exec(db, "INSERT OR REPLACE INTO images VALUES (?, ?, ?, ?, ?, ? ,?)", row)
    db
  end

  def get_image_(db, id_or_nametag) do
    IO.puts("LOL #{inspect(File.stat(Jocker.Engine.Config.metadata_db()))}")

    result =
      case fetch_all(db, "SELECT * FROM images WHERE id=?", [id_or_nametag]) do
        {:ok, []} ->
          {name, tag} = Jocker.Engine.Utils.decode_tagname(id_or_nametag)
          {:ok, rows} = fetch_all(db, "SELECT * FROM images WHERE name=? AND tag=?", [name, tag])
          rows

        {:ok, rows} ->
          rows
      end

    case result do
      [image_row] -> row2record(:image, image_row)
      [] -> :not_found
    end
  end

  @spec list_images_(Sqlitex.connection()) :: [Jocker.Engine.Records.image()]
  def list_images_(db) do
    {:ok, rows} =
      fetch_all(db, "SELECT * FROM images WHERE id != 'base' ORDER BY created DESC", [])

    images = Enum.map(rows, fn row -> row2record(:image, row) end)
    images
  end

  @spec add_container_(Sqlitex.connection(), Jocker.Engine.Records.container()) ::
          Sqlitex.connection()
  def add_container_(db, container) do
    row = record2row(container)
    :ok = exec(db, "INSERT OR REPLACE INTO containers VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", row)
    db
  end

  @spec get_container_(Sqlitex.connection(), String.t()) ::
          Jocker.Engine.Records.container() | :not_found
  def get_container_(db, id_or_name) do
    sql = """
    SELECT * FROM containers WHERE id=?
    UNION
    SELECT * FROM containers WHERE name=?
    """

    case fetch_all(db, sql, [id_or_name, id_or_name]) do
      {:ok, [row | _]} -> row2record(:container, row)
      {:ok, []} -> :not_found
    end
  end

  @spec list_containers_(Sqlitex.connection(), String.t()) ::
          Jocker.Engine.Records.container() | :not_found
  def list_containers_(db, opts) do
    sql =
      case Keyword.get(opts, :all, false) do
        false ->
          "SELECT * FROM containers WHERE id != 'base' AND running = 1 ORDER BY created DESC"

        true ->
          "SELECT * FROM containers WHERE id != 'base' ORDER BY created DESC"
      end

    {:ok, rows} = fetch_all(db, sql, [])
    Enum.map(rows, fn row -> row2record(:container, row) end)
  end

  @spec clear_tables_(Sqlitex.connection()) :: Sqlitex.connection()
  def clear_tables_(db) do
    drop_tables(db)
    create_tables(db)
    db
  end

  @spec row2record(record_type(), []) :: jocker_record()
  defp row2record(type, row) do
    Logger.debug("Converting #{inspect(type)}-row: #{inspect(row)}")

    record =
      case type do
        :container ->
          row_upd = Keyword.update(row, :command, nil, &decode/1)
          row_upd = Keyword.update(row_upd, :parameters, nil, &decode/1)
          row_upd = Keyword.update(row_upd, :running, nil, &int2bool/1)

          row_upd = Keyword.update(row_upd, :pid, nil, &str2pid/1)

          List.to_tuple([type | Keyword.values(row_upd)])

        :image ->
          row_upd = Keyword.update(row, :command, nil, &decode/1)
          List.to_tuple([type | Keyword.values(row_upd)])

        type ->
          List.to_tuple([type | Keyword.values(row)])
      end

    Logger.debug("Converted #{inspect(type)}-row: #{inspect(record)}")
    record
  end

  @spec record2row({}) :: []
  def record2row(rec) do
    Logger.debug("Converting record: #{inspect(rec)}")
    [type | values] = Tuple.to_list(rec)

    row =
      case type do
        :container ->
          container(command: cmd, parameters: param, running: running, pid: pid) = rec
          running_integer = bool2int(running)
          cmd_json = encode(cmd)
          param_json = encode(param)
          pid_str = pid2str(pid)

          [_type | new_values] =
            Tuple.to_list(
              container(rec,
                command: cmd_json,
                parameters: param_json,
                running: running_integer,
                pid: pid_str
              )
            )

          new_values

        :image ->
          image(command: cmd) = rec
          cmd_json = encode(cmd)
          [_type | new_values] = Tuple.to_list(image(rec, command: cmd_json))
          new_values

        _type ->
          values
      end

    Logger.debug("Converted record: #{inspect(row)}")
    row
  end

  def bool2int(true), do: 1
  def bool2int(false), do: 0

  def int2bool(1), do: true
  def int2bool(0), do: false

  def pid2str(nil), do: ""
  def pid2str(:none), do: ""
  def pid2str(pid), do: List.to_string(:erlang.pid_to_list(pid))

  def str2pid(""), do: nil
  def str2pid(pidstr), do: :erlang.list_to_pid(String.to_charlist(pidstr))

  defp decode(json) do
    {:ok, term} = Jason.decode(json)
    term
  end

  defp encode(term) do
    {:ok, cmd_json} = Jason.encode(term)
    cmd_json
  end

  def fetch_all(db, sql, values \\ []) do
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, statement} = Sqlitex.Statement.bind_values(statement, values)
    Sqlitex.Statement.fetch_all(statement)
  end

  def exec(db, sql, values \\ []) do
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, statement} = Sqlitex.Statement.bind_values(statement, values)
    Sqlitex.Statement.exec(statement)
  end

  def drop_tables(db) do
    {:ok, []} = Sqlitex.query(db, "DROP TABLE images")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE containers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE layers")
  end

  def create_tables(db) do
    base_layer =
      layer(
        id: "base",
        dataset: Config.base_layer_dataset(),
        snapshot: Config.base_layer_snapshot(),
        mountpoint: Config.base_layer_mountpoint()
      )

    base_image =
      image(
        id: "base",
        tag: "base",
        layer_id: "base"
      )

    {:ok, []} = Sqlitex.query(db, @table_layers)
    {:ok, []} = Sqlitex.query(db, @table_images)
    {:ok, []} = Sqlitex.query(db, @table_containers)
    add_layer_(db, base_layer)
    add_image_(db, base_image)
  end
end
