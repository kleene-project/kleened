defmodule Jocker.Engine.MetaData do
  require Logger
  alias Jocker.Engine.{Config, Image, Container, Network}
  alias Jocker.Engine.Network.EndPointConfig
  alias Jocker.Engine.Records, as: JockerRecords
  import JockerRecords

  use Agent

  @table_network """
  CREATE TABLE IF NOT EXISTS
  networks (
    network TEXT
  )
  """

  @table_endpoint_configs """
  CREATE TABLE IF NOT EXISTS
  endpoint_configs (
    container_id TEXT,
    network_id   TEXT,
    config       TEXT
  )
  """

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
    id    TEXT PRIMARY KEY,
    image TEXT
    )
  """

  @table_containers """
  CREATE TABLE IF NOT EXISTS
  containers (
    id        TEXT PRIMARY KEY,
    container TEXT
    )
  """

  @view_api_list_containers """
  CREATE VIEW IF NOT EXISTS api_list_containers
  AS
  SELECT
    containers.id,
    json_extract(containers.container, '$.name') AS name,
    json_extract(containers.container, '$.command') AS command,
    json_extract(containers.container, '$.image_id') AS image_id,
    json_extract(containers.container, '$.created') AS created,
    json_extract(images.image, '$.name') AS image_name,
    json_extract(images.image, '$.tag') AS image_tag
  FROM
    containers
  INNER JOIN images ON json_extract(containers.container, '$.image_id') = images.id;
  """

  @table_volumes """
  CREATE TABLE IF NOT EXISTS
  volumes (
    name       TEXT PRIMARY KEY,
    dataset    TEXT,
    mountpoint TEXT,
    created    TEXT
    )
  """

  @table_mounts """
  CREATE TABLE IF NOT EXISTS
  mounts (
    container_id TEXT,
    volume_name  TEXT,
    location     TEXT,
    read_only    INTEGER
    )
  """

  @type jocker_record() ::
          JockerRecords.layer()
          | JockerRecords.container()
          | JockerRecords.image()
          | JockerRecords.volume()
          | JockerRecords.mount()

  @type record_type() :: :image | :layer | :container

  @type db_conn() :: Sqlitex.connection()

  @spec start_link([]) :: Agent.on_start()
  def start_link([]) do
    filepath = Config.get("metadata_db")
    {:ok, db} = Sqlitex.open(filepath)
    create_tables(db)
    Agent.start_link(fn -> db end, name: __MODULE__)
  end

  def stop() do
    Agent.stop(__MODULE__)
  end

  @spec add_network(%Network{}) :: :ok
  def add_network(network) do
    Agent.get(__MODULE__, fn db -> add_network_(db, network) end)
  end

  @spec remove_network(String.t()) :: :ok | :not_found
  def remove_network(network_id) do
    Agent.get(__MODULE__, fn db -> remove_network_(db, network_id) end)
  end

  @spec get_network(String.t()) :: %Network{} | :not_found
  def get_network(name_or_id) do
    Agent.get(__MODULE__, fn db -> get_network_(db, name_or_id) end)
  end

  @spec list_networks(:include_host | :exclude_host) :: [%Network{}]
  def list_networks(mode \\ :include_host) do
    Agent.get(__MODULE__, fn db -> list_networks_(db, mode) end)
  end

  @spec add_endpoint_config(
          Container.container_id(),
          Network.network_id(),
          %EndPointConfig{}
        ) :: :ok
  def add_endpoint_config(container_id, network_id, endpoint_config) do
    Agent.get(__MODULE__, fn db ->
      add_endpoint_config_(db, container_id, network_id, endpoint_config)
    end)
  end

  @spec get_endpoint_config(Container.container_id(), Network.network_id()) ::
          %EndPointConfig{} | :not_found
  def get_endpoint_config(container_id, network_id) do
    Agent.get(__MODULE__, fn db -> get_endpoint_config_(db, container_id, network_id) end)
  end

  @spec remove_endpoint_config(Container.container_id(), Network.network_id()) :: :ok
  def remove_endpoint_config(container_id, network_id) do
    Agent.get(__MODULE__, fn db -> remove_endpoint_config_(db, container_id, network_id) end)
  end

  @spec connected_containers(Network.network_id()) :: [Container.container_id()]
  def connected_containers(network_id) do
    Agent.get(__MODULE__, fn db -> connected_containers_(db, network_id) end)
  end

  @spec connected_networks(Container.container_id()) :: [Network.network_id()]
  def connected_networks(container_id) do
    Agent.get(__MODULE__, fn db -> connected_networks_(db, container_id) end)
  end

  @spec add_layer(JockerRecords.layer()) :: :ok
  def add_layer(layer) do
    Agent.get(__MODULE__, fn db -> add_layer_(db, layer) end)
  end

  @spec get_layer(String.t()) :: JockerRecords.layer() | :not_found
  def get_layer(layer_id) do
    Agent.get(__MODULE__, fn db -> get_layer_(db, layer_id) end)
  end

  @spec remove_layer(String.t()) :: :ok
  def remove_layer(layer_id) do
    Agent.get(__MODULE__, fn db -> remove_layer_(db, layer_id) end)
  end

  @spec add_image(%Image{}) :: :ok
  def add_image(image) do
    Agent.get(__MODULE__, fn db -> add_image_(db, image) end)
  end

  @spec get_image(String.t()) :: JockerRecords.image() | :not_found
  def get_image(id_or_nametag) do
    Agent.get(__MODULE__, fn db -> get_image_(db, id_or_nametag) end)
  end

  @spec delete_image(String.t()) :: :ok
  def delete_image(id) do
    Agent.get(__MODULE__, fn db -> delete_image_(db, id) end)
  end

  @spec list_images() :: [JockerRecords.image()]
  def list_images() do
    Agent.get(__MODULE__, fn db -> list_images_(db) end)
  end

  @spec add_container(JockerRecords.container()) :: :ok
  def add_container(container) do
    Agent.get(__MODULE__, fn db -> add_container_(db, container) end)
  end

  @spec delete_container(Container.container_id()) :: :ok
  def delete_container(id) do
    Agent.get(__MODULE__, fn db -> delete_container_(db, id) end)
  end

  @spec get_container(String.t()) :: JockerRecords.container() | :not_found
  def get_container(id_or_name) do
    Agent.get(__MODULE__, fn db -> get_container_(db, id_or_name) end)
  end

  @spec list_containers() :: [JockerRecords.container()]
  def list_containers() do
    Agent.get(__MODULE__, fn db -> list_containers_(db) end)
  end

  @spec add_volume(JockerRecords.volume()) :: :ok
  def add_volume(volume) do
    Agent.get(__MODULE__, fn db -> add_volume_(db, volume) end)
  end

  @spec get_volume(String.t()) :: JockerRecords.volume() | :not_found
  def get_volume(name) do
    Agent.get(__MODULE__, fn db -> get_volume_(db, name) end)
  end

  @spec remove_volume(JockerRecords.volume()) :: :ok | :not_found
  def remove_volume(volume) do
    Agent.get(__MODULE__, fn db -> remove_volume_(db, volume) end)
  end

  @spec list_volumes([]) :: [JockerRecords.volume()]
  def list_volumes(opts \\ []) do
    Agent.get(__MODULE__, fn db -> list_volumes_(db, opts) end)
  end

  @spec add_mount(JockerRecords.mount()) :: :ok
  def add_mount(mount) do
    Agent.get(__MODULE__, fn db -> add_mount_(db, mount) end)
  end

  @spec remove_mounts_by_container(JockerRecords.container()) :: :ok | :not_found
  def remove_mounts_by_container(container) do
    Agent.get(__MODULE__, fn db -> remove_mounts_(db, container) end)
  end

  @spec remove_mounts_by_volume(JockerRecords.volume()) :: :ok | :not_found
  def remove_mounts_by_volume(volume) do
    Agent.get(__MODULE__, fn db -> remove_mounts_(db, volume) end)
  end

  @spec list_mounts(JockerRecords.volume()) :: [JockerRecords.mount()]
  def list_mounts(volume) do
    Agent.get(__MODULE__, fn db -> list_mounts_(db, volume) end)
  end

  @spec clear_tables() :: :ok
  def clear_tables() do
    Agent.get(__MODULE__, fn db -> clear_tables_(db) end)
  end

  ##########################
  ### Internal functions ###
  ##########################
  def add_network_(db, network) do
    json = to_json(network)
    exec(db, "INSERT OR REPLACE INTO networks VALUES (?)", [json])
  end

  def get_network_(db, id_or_name) do
    sql = """
    SELECT network FROM networks WHERE substr(json_extract(network, '$.id'), 1, ?) = ?
    UNION
    SELECT network FROM networks WHERE json_extract(network, '$.name') = ?
    """

    case fetch_all(db, sql, [String.length(id_or_name), id_or_name, id_or_name]) do
      {:ok, [[network: json] | _]} ->
        from_json(:network, json)

      {:ok, []} ->
        :not_found
    end
  end

  def remove_network_(db, network_id) do
    exec(db, "DELETE FROM networks WHERE json_extract(network, '$.id') = ?", [network_id])
  end

  @spec list_networks_(db_conn(), :include_host | :exclude_host) :: [%Network{}]
  def list_networks_(db, mode) do
    sql =
      case mode do
        :include_host ->
          "SELECT network FROM networks"

        :exclude_host ->
          "SELECT network FROM networks WHERE json_extract(network, '$.id') != 'host'"
      end

    {:ok, rows} = fetch_all(db, sql)
    Enum.map(rows, fn [network: json] -> from_json(:network, json) end)
  end

  def add_endpoint_config_(db, container_id, network_id, endpoint_config) do
    sql =
      "INSERT OR REPLACE INTO endpoint_configs(container_id, network_id, config) VALUES (?, ?, ?)"

    exec(db, sql, [container_id, network_id, to_json(endpoint_config)])
  end

  def get_endpoint_config_(db, container_id, network_id) do
    sql = "SELECT config FROM endpoint_configs WHERE container_id = ? AND network_id = ?"
    param = [container_id, network_id]
    {:ok, rows} = fetch_all(db, sql, param)
    [row] = Enum.map(rows, fn [config: json] -> from_json(:endpoint_config, json) end)
    row
  end

  def remove_endpoint_config_(db, container_id, network_id) do
    sql = "DELETE FROM endpoint_configs WHERE container_id = ? AND network_id = ?"
    exec(db, sql, [container_id, network_id])
  end

  def connected_containers_(db, network_id) do
    sql = "SELECT container_id FROM endpoint_configs WHERE network_id = ?"
    {:ok, rows} = fetch_all(db, sql, [network_id])
    Enum.map(rows, fn [container_id: id] -> id end)
  end

  def connected_networks_(db, container_id) do
    sql = "SELECT network_id FROM endpoint_configs WHERE container_id = ?"
    {:ok, rows} = fetch_all(db, sql, [container_id])
    Enum.map(rows, fn [network_id: id] -> id end)
  end

  def add_layer_(db, layer) do
    row = record2row(layer)
    exec(db, "INSERT OR REPLACE INTO layers VALUES (?, ?, ?, ?, ?)", row)
  end

  def get_layer_(db, layer_id) do
    case fetch_all(db, "SELECT * FROM layers WHERE id=?", [layer_id]) do
      {:ok, [row]} -> row2record(:layer, row)
      {:ok, []} -> :not_found
    end
  end

  def remove_layer_(db, layer_id) do
    exec(db, "DELETE FROM layers WHERE id = ?", [layer_id])
  end

  def add_image_(db, %Image{name: new_name, tag: new_tag} = image) do
    sql = """
    SELECT id, image FROM images
      WHERE json_extract(image, '$.name') != ''
        AND json_extract(image, '$.tag') != ''
        AND json_extract(image, '$.name') = ?
        AND json_extract(image, '$.tag') = ?
    """

    result = fetch_all(db, sql, [new_name, new_tag])

    case result do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        [img] = from_db(rows)
        existing_image = %{img | name: "", tag: ""}
        {id, json} = to_db(existing_image)
        :ok = exec(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    end

    {id, json} = to_db(image)
    :ok = exec(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    db
  end

  def get_image_(db, id_or_nametag) do
    select_by_id = "SELECT id, image FROM images WHERE id = ?"

    select_by_nametag =
      "SELECT id, image FROM images WHERE json_extract(image, '$.name') = ? AND json_extract(image, '$.tag') = ?"

    result =
      case fetch_all(db, select_by_id, [id_or_nametag]) do
        {:ok, []} ->
          {name, tag} = Jocker.Engine.Utils.decode_tagname(id_or_nametag)
          fetch_all(db, select_by_nametag, [name, tag])

        {:ok, rows} ->
          {:ok, rows}
      end

    case result do
      {:ok, []} ->
        :not_found

      {:ok, rows} ->
        [image] = from_db(rows)
        image
    end
  end

  @spec delete_image_(db_conn(), String.t()) :: :ok
  def delete_image_(db, id) do
    exec(db, "DELETE FROM images WHERE id = ?", [id])
  end

  @spec list_images_(db_conn()) :: [%Image{}]
  def list_images_(db) do
    query =
      "SELECT id, image FROM images WHERE id != 'base' ORDER BY json_extract(image, '$.created') DESC"

    fetch_all(db, query, []) |> from_db
  end

  @spec add_container_(db_conn(), %Container{}) :: :ok
  def add_container_(db, container) do
    {id, json} = to_db(container)
    exec(db, "INSERT OR REPLACE INTO containers(id, container) VALUES (?, ?)", [id, json])
  end

  @spec delete_container_(db_conn(), %Container{}) :: db_conn()
  def delete_container_(db, id) do
    exec(db, "DELETE FROM containers WHERE id = ?", [id])
  end

  @spec get_container_(db_conn(), String.t()) :: %Container{} | :not_found
  def get_container_(db, id_or_name) do
    sql = """
    SELECT id, container FROM containers WHERE id=?
    UNION
    SELECT id, container FROM containers WHERE json_extract(container, '$.name')=?
    """

    result = fetch_all(db, sql, [id_or_name, id_or_name]) |> from_db()

    case result do
      [] -> :not_found
      [row | _rest] -> row
    end
  end

  @spec list_containers_(db_conn()) :: [term()]
  def list_containers_(db) do
    sql = "SELECT * FROM api_list_containers WHERE id != 'base' ORDER BY created DESC"
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, rows} = Sqlitex.Statement.fetch_all(statement, into: %{})
    rows
  end

  @spec add_volume_(db_conn(), JockerRecords.volume()) :: :ok
  def add_volume_(db, volume) do
    row = record2row(volume)
    exec(db, "INSERT OR REPLACE INTO volumes VALUES (?, ?, ?, ?)", row)
  end

  @spec get_volume_(db_conn(), String.t()) :: JockerRecords.volume()
  def get_volume_(db, name) do
    sql = "SELECT * FROM volumes WHERE name = ?"

    case fetch_all(db, sql, [name]) do
      {:ok, []} -> :not_found
      {:ok, [row]} -> row2record(:volume, row)
    end
  end

  @spec remove_volume_(db_conn(), JockerRecords.volume()) :: :ok
  def remove_volume_(db, volume(name: name)) do
    sql = "DELETE FROM volumes WHERE name = ?;"
    :ok = exec(db, sql, [name])
  end

  @spec list_volumes_(db_conn(), String.t()) ::
          [JockerRecords.volume()]
  def list_volumes_(db, _opts) do
    sql = "SELECT * FROM volumes ORDER BY created DESC"
    {:ok, rows} = fetch_all(db, sql, [])
    Enum.map(rows, fn row -> row2record(:volume, row) end)
  end

  @spec add_mount_(db_conn(), JockerRecords.mount()) :: :ok
  def add_mount_(db, mount) do
    row = record2row(mount)
    exec(db, "INSERT OR REPLACE INTO mounts VALUES (?, ?, ?, ?)", row)
  end

  @spec remove_mounts_(
          db_conn(),
          JockerRecords.volume() | %Container{}
        ) :: :ok
  def remove_mounts_(db, %Container{id: id}) do
    {:ok, rows} = fetch_all(db, "SELECT * FROM mounts WHERE container_id=?", [id])
    :ok = exec(db, "DELETE FROM mounts WHERE container_id = ?;", [id])
    Enum.map(rows, fn row -> row2record(:mount, row) end)
  end

  def remove_mounts_(db, volume(name: name)) do
    {:ok, rows} = fetch_all(db, "SELECT * FROM mounts WHERE volume_name=?", [name])
    :ok = exec(db, "DELETE FROM mounts WHERE volume_name=?;", [name])
    Enum.map(rows, fn row -> row2record(:mount, row) end)
  end

  @spec list_mounts_(db_conn(), JockerRecords.volume()) ::
          [JockerRecords.mount()]
  def list_mounts_(db, volume(name: name)) do
    sql = "SELECT * FROM mounts WHERE volume_name = ?"
    {:ok, rows} = fetch_all(db, sql, [name])
    Enum.map(rows, fn row -> row2record(:mount, row) end)
  end

  @spec clear_tables_(db_conn()) :: db_conn()
  def clear_tables_(db) do
    drop_tables(db)
    create_tables(db)
  end

  @spec to_db(%Image{}) :: String.t()
  def to_db(struct) do
    map = Map.from_struct(struct)
    {id, map} = Map.pop(map, :id)

    map =
      case struct.__struct__ do
        Container ->
          %{map | pid: pid2str(map[:pid])}

        _rest ->
          map
      end

    {:ok, json} = Jason.encode(map)
    {id, json}
  end

  @spec from_db(keyword() | {:ok, keyword()}) :: [%Image{}]
  def from_db({:ok, rows}) do
    from_db(rows)
  end

  def from_db(rows) do
    rows |> Enum.map(&transform_row(&1))
  end

  @spec transform_row(List.t()) :: %Image{}
  def transform_row(row) do
    id = Keyword.get(row, :id)

    {struct_type, map} =
      cond do
        Keyword.has_key?(row, :image) ->
          image = Keyword.get(row, :image)
          {:ok, map} = Jason.decode(image, [{:keys, :atoms}])
          {Image, map}

        Keyword.has_key?(row, :container) ->
          image = Keyword.get(row, :container)
          {:ok, %{pid: pid_str} = map} = Jason.decode(image, [{:keys, :atoms}])
          {Container, %{map | pid: str2pid(pid_str)}}
      end

    struct(struct_type, Map.put(map, :id, id))
  end

  @spec to_json(%Network{} | %EndPointConfig{}) :: String.t()
  def to_json(struct) do
    {:ok, json} = Jason.encode(struct)
    json
  end

  @spec from_json(:network | :endpoint_config, String.t()) :: %Network{}
  def from_json(:network, network) do
    {:ok, map} = Jason.decode(network, [{:keys, :atoms}])
    struct(Network, map)
  end

  def from_json(:endpoint_config, config) do
    {:ok, map} = Jason.decode(config, [{:keys, :atoms}])
    struct(EndPointConfig, map)
  end

  def decode_endpoint_configs(json) do
    networking_cfg_list = Enum.map(Map.to_list(decode(json)), &decode_endpoint_configs_/1)
    Map.new(networking_cfg_list)
  end

  def decode_endpoint_configs_({endpointkey, endpointcfg_map}) do
    endpointcfg_with_atom_keys =
      for {key, val} <- endpointcfg_map, into: %{} do
        {String.to_existing_atom(key), val}
      end

    {endpointkey, struct(EndPointConfig, endpointcfg_with_atom_keys)}
  end

  @spec row2record(record_type(), []) :: jocker_record()
  defp row2record(type, row) do
    record =
      case type do
        :container ->
          row_upd = Keyword.update(row, :command, nil, &decode/1)
          row_upd = Keyword.update(row_upd, :parameters, nil, &decode/1)
          row_upd = Keyword.update(row_upd, :pid, :none, &str2pid/1)

          List.to_tuple([type | Keyword.values(row_upd)])

        :mount ->
          row_upd = Keyword.update(row, :read_only, nil, &int2bool/1)
          List.to_tuple([type | Keyword.values(row_upd)])

        type ->
          List.to_tuple([type | Keyword.values(row)])
      end

    record
  end

  @spec record2row(jocker_record()) :: [term()]
  def record2row(rec) do
    [type | values] = Tuple.to_list(rec)

    row =
      case type do
        :mount ->
          mount(read_only: ro) = rec
          ro_integer = bool2int(ro)
          [_type | new_values] = Tuple.to_list(mount(rec, read_only: ro_integer))
          new_values

        _type ->
          values
      end

    # Logger.debug("Converted record: #{inspect(row)}")
    row
  end

  def bool2int(true), do: 1
  def bool2int(false), do: 0

  def int2bool(1), do: true
  def int2bool(0), do: false

  def pid2str(""), do: ""
  def pid2str(pid), do: List.to_string(:erlang.pid_to_list(pid))

  def str2pid(""), do: ""
  def str2pid(pidstr), do: :erlang.list_to_pid(String.to_charlist(pidstr))

  defp decode(json, opts \\ []) do
    {:ok, term} = Jason.decode(json, opts)
    term
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
    {:ok, []} = Sqlitex.query(db, "DROP VIEW api_list_containers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE images")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE containers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE layers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE volumes")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE mounts")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE networks")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE endpoint_configs")
  end

  def create_tables(db) do
    base_layer =
      layer(
        id: "base",
        dataset: Config.get("base_layer_dataset"),
        snapshot: Config.get("base_layer_snapshot"),
        mountpoint: :none
      )

    base_image = %Image{
      id: "base",
      layer_id: "base",
      name: "",
      tag: "",
      user: "root"
    }

    {:ok, []} = Sqlitex.query(db, @table_network)
    {:ok, []} = Sqlitex.query(db, @table_endpoint_configs)
    {:ok, []} = Sqlitex.query(db, @table_layers)
    {:ok, []} = Sqlitex.query(db, @table_images)
    {:ok, []} = Sqlitex.query(db, @table_containers)
    {:ok, []} = Sqlitex.query(db, @table_volumes)
    {:ok, []} = Sqlitex.query(db, @table_mounts)
    {:ok, []} = Sqlitex.query(db, @view_api_list_containers)
    add_layer_(db, base_layer)
    add_image_(db, base_image)
  end
end
