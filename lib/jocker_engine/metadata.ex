defmodule Jocker.Engine.MetaData do
  require Logger
  alias Jocker.Engine.{Config, Layer, Image, Container, Network, Volume, Volume.Mount}
  alias Jocker.Engine.Network.EndPointConfig

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
    id    TEXT PRIMARY KEY,
    layer TEXT
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

  @table_volumes """
  CREATE TABLE IF NOT EXISTS
  volumes ( name TEXT PRIMARY KEY, volume TEXT )
  """

  @table_mounts """
  CREATE TABLE IF NOT EXISTS
  mounts ( mount TEXT )
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

  @type jocker_record() ::
          Layer.t()
          | Container.container()
          | Image.image()
          | Volume.volume()
          | Mount.mount()

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

  @spec add_layer(Layer.t()) :: :ok
  def add_layer(layer) do
    Agent.get(__MODULE__, fn db -> add_layer_(db, layer) end)
  end

  @spec get_layer(String.t()) :: Layer.t() | :not_found
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

  @spec get_image(String.t()) :: Image.t() | :not_found
  def get_image(id_or_nametag) do
    Agent.get(__MODULE__, fn db -> get_image_(db, id_or_nametag) end)
  end

  @spec delete_image(String.t()) :: :ok
  def delete_image(id) do
    Agent.get(__MODULE__, fn db -> delete_image_(db, id) end)
  end

  @spec list_images() :: [Image.t()]
  def list_images() do
    Agent.get(__MODULE__, fn db -> list_images_(db) end)
  end

  @spec add_container(Container.t()) :: :ok
  def add_container(container) do
    Agent.get(__MODULE__, fn db -> add_container_(db, container) end)
  end

  @spec delete_container(Container.t()) :: :ok
  def delete_container(id) do
    Agent.get(__MODULE__, fn db -> delete_container_(db, id) end)
  end

  @spec get_container(String.t()) :: Container.t() | :not_found
  def get_container(id_or_name) do
    Agent.get(__MODULE__, fn db -> get_container_(db, id_or_name) end)
  end

  @spec list_containers() :: [JockerRecords.container()]
  def list_containers() do
    Agent.get(__MODULE__, fn db -> list_containers_(db) end)
  end

  @spec add_volume(Volume.t()) :: :ok
  def add_volume(volume) do
    Agent.get(__MODULE__, fn db -> add_volume_(db, volume) end)
  end

  @spec get_volume(String.t()) :: Volume.t() | :not_found
  def get_volume(name) do
    Agent.get(__MODULE__, fn db -> get_volume_(db, name) end)
  end

  @spec remove_volume(Volume.t()) :: :ok | :not_found
  def remove_volume(volume) do
    Agent.get(__MODULE__, fn db -> remove_volume_(db, volume) end)
  end

  @spec list_volumes([]) :: [Volume.t()]
  def list_volumes(opts \\ []) do
    Agent.get(__MODULE__, fn db -> list_volumes_(db, opts) end)
  end

  @spec add_mount(Mount.t()) :: :ok
  def add_mount(mount) do
    Agent.get(__MODULE__, fn db -> add_mount_(db, mount) end)
  end

  @spec remove_mounts_by_container(Container.t()) :: :ok | :not_found
  def remove_mounts_by_container(container) do
    Agent.get(__MODULE__, fn db -> remove_mounts_(db, container) end)
  end

  @spec remove_mounts_by_volume(Volume.t()) :: :ok | :not_found
  def remove_mounts_by_volume(volume) do
    Agent.get(__MODULE__, fn db -> remove_mounts_(db, volume) end)
  end

  @spec list_mounts(Volume.t()) :: [Mount.t()]
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
    json = to_db(network)
    exec(db, "INSERT OR REPLACE INTO networks VALUES (?)", [json])
  end

  def get_network_(db, id_or_name) do
    sql = """
    SELECT network FROM networks WHERE substr(json_extract(network, '$.id'), 1, ?) = ?
    UNION
    SELECT network FROM networks WHERE json_extract(network, '$.name') = ?
    """

    result = fetch_all(db, sql, [String.length(id_or_name), id_or_name, id_or_name])

    case result do
      [row] -> row
      [] -> :not_found
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

    fetch_all(db, sql)
  end

  def add_endpoint_config_(db, container_id, network_id, endpoint_config) do
    sql =
      "INSERT OR REPLACE INTO endpoint_configs(container_id, network_id, config) VALUES (?, ?, ?)"

    exec(db, sql, [container_id, network_id, to_db(endpoint_config)])
  end

  def get_endpoint_config_(db, container_id, network_id) do
    sql = "SELECT config FROM endpoint_configs WHERE container_id = ? AND network_id = ?"
    param = [container_id, network_id]
    [endpoint_cfg] = fetch_all(db, sql, param)
    endpoint_cfg
  end

  def remove_endpoint_config_(db, container_id, network_id) do
    sql = "DELETE FROM endpoint_configs WHERE container_id = ? AND network_id = ?"
    exec(db, sql, [container_id, network_id])
  end

  def connected_containers_(db, network_id) do
    sql = "SELECT container_id FROM endpoint_configs WHERE network_id = ?"
    fetch_all(db, sql, [network_id])
  end

  def connected_networks_(db, container_id) do
    sql = "SELECT network_id FROM endpoint_configs WHERE container_id = ?"
    fetch_all(db, sql, [container_id])
  end

  def add_layer_(db, layer) do
    {id, json} = to_db(layer)
    exec(db, "INSERT OR REPLACE INTO layers(id, layer) VALUES (?, ?)", [id, json])
  end

  def get_layer_(db, layer_id) do
    result = fetch_all(db, "SELECT id, layer FROM layers WHERE id=?", [layer_id])

    case result do
      [layer] -> layer
      [] -> :not_found
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
      [] ->
        :ok

      [img] ->
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
        [] ->
          {name, tag} = Jocker.Engine.Utils.decode_tagname(id_or_nametag)
          fetch_all(db, select_by_nametag, [name, tag])

        rows ->
          rows
      end

    case result do
      [] -> :not_found
      [image] -> image
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

    fetch_all(db, query, [])
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

    result = fetch_all(db, sql, [id_or_name, id_or_name])

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

  @spec add_volume_(db_conn(), Volume.t()) :: :ok
  def add_volume_(db, volume) do
    {name, volume} = to_db(volume)
    exec(db, "INSERT OR REPLACE INTO volumes(name, volume) VALUES (?, ?)", [name, volume])
  end

  @spec get_volume_(db_conn(), String.t()) :: Volume.t()
  def get_volume_(db, name) do
    sql = "SELECT name, volume FROM volumes WHERE name = ?"
    result = fetch_all(db, sql, [name])

    case result do
      [] -> :not_found
      [row] -> row
    end
  end

  @spec remove_volume_(db_conn(), Volume.t()) :: :ok
  def remove_volume_(db, %Volume{name: name}) do
    sql = "DELETE FROM volumes WHERE name = ?"
    :ok = exec(db, sql, [name])
  end

  @spec list_volumes_(db_conn(), String.t()) ::
          [JockerRecords.volume()]
  def list_volumes_(db, _opts) do
    sql = "SELECT name, volume FROM volumes ORDER BY json_extract(volume, '$.created') DESC"
    fetch_all(db, sql, [])
  end

  @spec add_mount_(db_conn(), Mount.t()) :: :ok
  def add_mount_(db, mount) do
    row = to_db(mount)
    exec(db, "INSERT OR REPLACE INTO mounts VALUES (?)", [row])
  end

  @spec remove_mounts_(
          db_conn(),
          Volume.t() | Container.t()
        ) :: :ok
  def remove_mounts_(db, %Container{id: id}) do
    result =
      fetch_all(db, "SELECT mount FROM mounts WHERE json_extract(mount, '$.container_id') = ?", [
        id
      ])

    :ok = exec(db, "DELETE FROM mounts WHERE json_extract(mount, '$.container_id') = ?;", [id])
    result
  end

  def remove_mounts_(db, %Volume{name: name}) do
    result =
      fetch_all(db, "SELECT mount FROM mounts WHERE json_extract(mount, '$.volume_name') = ?", [
        name
      ])

    :ok = exec(db, "DELETE FROM mounts WHERE json_extract(mount, '$.volume_name') = ?;", [name])
    result
  end

  @spec list_mounts_(db_conn(), Volume.t()) :: [Mount.t()]
  def list_mounts_(db, %Volume{name: name}) do
    sql = "SELECT mount FROM mounts WHERE json_extract(mount, '$.volume_name') = ?"
    fetch_all(db, sql, [name])
  end

  @spec clear_tables_(db_conn()) :: db_conn()
  def clear_tables_(db) do
    drop_tables(db)
    create_tables(db)
  end

  @spec to_db(Image.t() | Container.t() | %Volume{} | %Mount{}) :: String.t()
  defp to_db(struct) do
    map = Map.from_struct(struct)

    case struct.__struct__ do
      Image ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Layer ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Container ->
        map = %{map | pid: pid2str(map[:pid])}
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Volume ->
        {name, map} = Map.pop(map, :name)
        {:ok, json} = Jason.encode(map)
        {name, json}

      type when type == Mount or type == Network or type == EndPointConfig ->
        {:ok, json} = Jason.encode(map)
        json
    end
  end

  @spec from_db(keyword() | {:ok, keyword()}) :: [%Image{}]
  defp from_db({:ok, rows}) do
    from_db(rows)
  end

  defp from_db(rows) do
    rows |> Enum.map(&transform_row(&1))
  end

  @spec transform_row(List.t()) :: %Image{}
  def transform_row(row) do
    {type, obj} =
      cond do
        Keyword.has_key?(row, :image) ->
          map = from_json(row, :image)
          id = Keyword.get(row, :id)
          {Image, Map.put(map, :id, id)}

        Keyword.has_key?(row, :layer) ->
          map = from_json(row, :layer)
          id = Keyword.get(row, :id)
          {Layer, Map.put(map, :id, id)}

        Keyword.has_key?(row, :container) ->
          %{pid: pid_str} = map = from_json(row, :container)
          id = Keyword.get(row, :id)
          map = Map.put(map, :id, id)
          {Container, %{map | pid: str2pid(pid_str)}}

        Keyword.has_key?(row, :volume) ->
          map = from_json(row, :volume)
          name = Keyword.get(row, :name)
          {Volume, Map.put(map, :name, name)}

        Keyword.has_key?(row, :mount) ->
          {Mount, from_json(row, :mount)}

        Keyword.has_key?(row, :network) ->
          {Network, from_json(row, :network)}

        Keyword.has_key?(row, :config) ->
          {EndPointConfig, from_json(row, :config)}

        Keyword.has_key?(row, :container_id) ->
          {:no_struct, Keyword.get(row, :container_id)}

        Keyword.has_key?(row, :network_id) ->
          {:no_struct, Keyword.get(row, :network_id)}
      end

    cond do
      type == :no_struct -> obj
      true -> struct(type, obj)
    end
  end

  defp from_json(row, element) do
    obj = Keyword.get(row, element)
    {:ok, json} = Jason.decode(obj, [{:keys, :atoms}])
    json
  end

  def pid2str(""), do: ""
  def pid2str(pid), do: List.to_string(:erlang.pid_to_list(pid))

  def str2pid(""), do: ""
  def str2pid(pidstr), do: :erlang.list_to_pid(String.to_charlist(pidstr))

  def fetch_all(db, sql, values \\ []) do
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, statement} = Sqlitex.Statement.bind_values(statement, values)
    Sqlitex.Statement.fetch_all(statement) |> from_db
  end

  defp exec(db, sql, values) do
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, statement} = Sqlitex.Statement.bind_values(statement, values)
    [] = Sqlitex.Statement.fetch_all(statement) |> from_db
    :ok
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
    base_layer = %Layer{
      id: "base",
      dataset: Config.get("base_layer_dataset"),
      snapshot: Config.get("base_layer_snapshot"),
      mountpoint: ""
    }

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
