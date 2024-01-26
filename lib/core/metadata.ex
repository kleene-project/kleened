defmodule Kleened.Core.MetaData do
  require Logger
  alias Kleened.Core.{Config, Image, Container, Network, Volume}
  alias Kleened.API.Schemas

  use Agent

  @table_network """
  CREATE TABLE IF NOT EXISTS
  networks (
    id      TEXT PRIMARY KEY,
    network TEXT
  )
  """

  @table_endpoint_configs """
  CREATE TABLE IF NOT EXISTS
  endpoint_configs (
    container_id TEXT,
    network_id   TEXT,
    config       TEXT,
    UNIQUE(container_id, network_id)
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
    json_extract(containers.container, '$.cmd') AS cmd,
    json_extract(containers.container, '$.image_id') AS image_id,
    json_extract(containers.container, '$.created') AS created,
    json_extract(images.image, '$.name') AS image_name,
    json_extract(images.image, '$.tag') AS image_tag
  FROM
    containers
  INNER JOIN images ON json_extract(containers.container, '$.image_id') = images.id;
  """

  @type db_conn() :: Sqlitex.connection()

  @spec start_link([]) :: Agent.on_start()
  def start_link([]) do
    filepath = Config.get("metadata_db")

    db =
      case Sqlitex.open(filepath) do
        {:error, {:cantopen, _error_msg}} ->
          Logger.error(
            "unable to open database at #{filepath}: Do you have the correct privileges?"
          )

        {:ok, db} ->
          db
      end

    create_tables(db)
    Agent.start_link(fn -> db end, name: __MODULE__)
  end

  def stop() do
    Agent.stop(__MODULE__)
  end

  @spec add_network(%Schemas.Network{}) :: :ok
  def add_network(network) do
    {id, json} = to_db(network)
    [] = sql("INSERT OR REPLACE INTO networks(id, network) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec remove_network(String.t()) :: :ok
  def remove_network(network_id) do
    [] = sql("DELETE FROM networks WHERE id = ?", [network_id])
    :ok
  end

  @spec get_network(String.t()) :: %Schemas.Network{} | :not_found
  def get_network(name_or_id) do
    query = """
    SELECT id, network FROM networks WHERE substr(id, 1, ?) = ?
    UNION
    SELECT id, network FROM networks WHERE json_extract(network, '$.name') = ?
    """

    case sql(query, [String.length(name_or_id), name_or_id, name_or_id]) do
      [row] -> row
      [] -> :not_found
    end
  end

  @spec list_networks() :: [%Schemas.Network{}]
  def list_networks() do
    sql("SELECT id, network FROM networks ORDER BY json_extract(network, '$.name')")
  end

  def list_unused_networks() do
    sql("""
    SELECT
      networks.id AS network_id,
      endpoint_configs.container_id AS endpoint
    FROM networks
    LEFT JOIN endpoint_configs ON networks.id = endpoint_configs.network_id
    WHERE networks.id != 'host' AND ifnull(endpoint_configs.container_id, 'empty') = 'empty';
    """)
  end

  @spec add_endpoint(
          Container.container_id(),
          Network.network_id(),
          %Schemas.EndPoint{}
        ) :: :ok
  def add_endpoint(container_id, network_id, endpoint_config) do
    sql(
      "INSERT OR REPLACE INTO endpoint_configs(container_id, network_id, config) VALUES (?, ?, ?)",
      [container_id, network_id, to_db(endpoint_config)]
    )

    :ok
  end

  @spec get_endpoint(Container.container_id(), Network.network_id()) ::
          %Schemas.EndPoint{} | :not_found
  def get_endpoint(container_id, network_id) do
    reply =
      sql(
        "SELECT config FROM endpoint_configs WHERE container_id = ? AND network_id = ?",
        [container_id, network_id]
      )

    case reply do
      [endpoint_cfg] -> endpoint_cfg
      [] -> :not_found
    end
  end

  @spec get_endpoints_from_network(Network.network_id()) :: [%Schemas.EndPoint{}]
  def get_endpoints_from_network(network_id) do
    sql(
      "SELECT config FROM endpoint_configs WHERE network_id = ?",
      [network_id]
    )
  end

  @spec get_endpoints_from_container(Container.container_id()) :: [%Schemas.EndPoint{}]
  def get_endpoints_from_container(container_id) do
    sql(
      "SELECT config FROM endpoint_configs WHERE container_id = ?",
      [container_id]
    )
  end

  @spec remove_endpoint_config(Container.container_id(), Network.network_id()) :: :ok
  def remove_endpoint_config(container_id, network_id) do
    sql("DELETE FROM endpoint_configs WHERE container_id = ? AND network_id = ?", [
      container_id,
      network_id
    ])

    :ok
  end

  @spec connected_containers(Network.network_id()) :: [Container.container_id()]
  def connected_containers(network_id) do
    sql("SELECT container_id FROM endpoint_configs WHERE network_id = ?", [network_id])
  end

  @spec connected_networks(Container.container_id()) :: [Network.network_id()]
  def connected_networks(container_id) do
    sql(
      "SELECT id, network FROM endpoint_configs INNER JOIN networks ON networks.id = network_id WHERE container_id = ?",
      [
        container_id
      ]
    )
  end

  @spec add_image(Image.t()) :: :ok
  def add_image(image) do
    Agent.get(__MODULE__, fn db -> add_image_transaction(db, image) end)
  end

  @spec get_image(String.t()) :: Image.t() | :not_found
  def get_image(id_or_nametag) do
    Agent.get(__MODULE__, fn db -> get_image_transaction(db, id_or_nametag) end)
  end

  @spec delete_image(String.t()) :: :ok
  def delete_image(id) do
    sql("DELETE FROM images WHERE id = ?", [id])
    :ok
  end

  @spec list_images() :: [Image.t()]
  def list_images() do
    sql("SELECT id, image FROM images ORDER BY json_extract(image, '$.created') DESC")
  end

  @spec add_container(Container.t()) :: :ok
  def add_container(container) do
    {id, json} = to_db(container)
    [] = sql("INSERT OR REPLACE INTO containers(id, container) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec delete_container(Container.t()) :: :ok
  def delete_container(id) do
    [] = sql("DELETE FROM containers WHERE id = ?", [id])
    :ok
  end

  @spec get_container(String.t()) :: Container.t() | :not_found
  def get_container(id_or_name) do
    query = """
    SELECT id, container FROM containers WHERE substr(id, 1, ?) = ?
    UNION
    SELECT id, container FROM containers WHERE json_extract(container, '$.name')=?
    """

    case sql(query, [String.length(id_or_name), id_or_name, id_or_name]) do
      [] -> :not_found
      [row | _rest] -> row
    end
  end

  @spec list_containers() :: [%{}]
  def list_containers() do
    sql("SELECT id, container FROM containers ORDER BY json_extract(container, '$.created')")
  end

  @spec container_listing() :: [%{}]
  def container_listing() do
    Agent.get(__MODULE__, fn db -> container_listing_transaction(db) end)
  end

  @spec add_volume(Volume.t()) :: :ok
  def add_volume(volume) do
    {name, volume} = to_db(volume)
    [] = sql("INSERT OR REPLACE INTO volumes(name, volume) VALUES (?, ?)", [name, volume])
    :ok
  end

  @spec get_volume(String.t()) :: Volume.t() | :not_found
  def get_volume(name) do
    result = sql("SELECT name, volume FROM volumes WHERE name = ?", [name])

    case result do
      [] -> :not_found
      [row] -> row
    end
  end

  @spec remove_volume(Volume.t()) :: :ok | :not_found
  def remove_volume(%{name: name}) do
    sql("DELETE FROM volumes WHERE name = ?", [name])
    :ok
  end

  @spec list_volumes() :: [Volume.t()]
  def list_volumes() do
    sql("SELECT name, volume FROM volumes ORDER BY json_extract(volume, '$.created') DESC")
  end

  @spec list_unused_volumes() :: [String.t()]
  def list_unused_volumes() do
    sql("""
    SELECT volumes.name
    FROM volumes
    LEFT JOIN mounts ON volumes.name = json_extract(mounts.mount, '$.source')
    WHERE ifnull(mounts.mount, 'empty') = 'empty';
    """)
  end

  @spec add_mount(%Schemas.MountPoint{}) :: :ok
  def add_mount(mount) do
    sql("INSERT OR REPLACE INTO mounts VALUES (?)", [to_db(mount)])
    :ok
  end

  @spec remove_mounts(Container.t() | Volume.t()) :: :ok | :not_found
  def remove_mounts(container_or_volume) do
    Agent.get(__MODULE__, fn db -> remove_mounts_transaction(db, container_or_volume) end)
  end

  @spec list_mounts(Volume.t()) :: [%Schemas.MountPoint{}]
  def list_mounts(%Schemas.Volume{name: name}) do
    sql("SELECT mount FROM mounts WHERE json_extract(mount, '$.source') = ?", [name])
  end

  @spec list_mounts_by_container(String.t()) :: [%Schemas.MountPoint{}] | :not_found
  def list_mounts_by_container(container_id) do
    sql("SELECT mount FROM mounts WHERE json_extract(mount, '$.container_id') = ?", [container_id])
  end

  @spec list_image_datasets() :: [%{}]
  def list_image_datasets() do
    sql("""
    SELECT images.id AS id,
         json_extract(images.image, '$.name') AS name,
         json_extract(images.image, '$.tag') AS tag,
         json_extract(images.image, '$.dataset') AS dataset
    FROM images;
    """)
  end

  ##########################
  ### Internal functions ###
  ##########################
  defp sql(sql, param \\ []) do
    Agent.get(__MODULE__, fn db -> execute_sql(db, sql, param) end)
  end

  defp execute_sql(db, sql, param) do
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, statement} = Sqlitex.Statement.bind_values(statement, param)
    Sqlitex.Statement.fetch_all(statement) |> from_db
  end

  @spec add_image_transaction(db_conn(), Image.t()) :: [term()]
  defp add_image_transaction(db, %Schemas.Image{name: new_name, tag: new_tag} = image) do
    query = """
    SELECT id, image FROM images
      WHERE json_extract(image, '$.name') != ''
        AND json_extract(image, '$.tag') != ''
        AND json_extract(image, '$.name') = ?
        AND json_extract(image, '$.tag') = ?
    """

    case execute_sql(db, query, [new_name, new_tag]) do
      [] ->
        :ok

      [existing_image] ->
        {id, json} = to_db(%{existing_image | name: "", tag: ""})
        execute_sql(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    end

    {id, json} = to_db(image)
    execute_sql(db, "INSERT OR REPLACE INTO images(id, image) VALUES (?, ?)", [id, json])
    :ok
  end

  @spec get_image_transaction(db_conn(), String.t()) :: [term()]
  defp get_image_transaction(db, id_or_nametag) do
    select_by_id = "SELECT id, image FROM images WHERE id = ?"
    {name, tag} = Kleened.Core.Utils.decode_tagname(id_or_nametag)

    select_by_nametag =
      "SELECT id, image FROM images WHERE json_extract(image, '$.name') = ? AND json_extract(image, '$.tag') = ?"

    result =
      case execute_sql(db, select_by_id, [id_or_nametag]) do
        [] -> execute_sql(db, select_by_nametag, [name, tag])
        rows -> rows
      end

    case result do
      [] -> :not_found
      [image] -> image
    end
  end

  @spec container_listing_transaction(db_conn()) :: [%{}]
  defp container_listing_transaction(db) do
    sql = "SELECT * FROM api_list_containers ORDER BY created DESC"
    {:ok, statement} = Sqlitex.Statement.prepare(db, sql)
    {:ok, rows} = Sqlitex.Statement.fetch_all(statement, into: %{})
    rows
  end

  @spec remove_mounts_transaction(
          db_conn(),
          Volume.t() | Container.t()
        ) :: :ok
  def remove_mounts_transaction(db, %Schemas.Container{id: id}) do
    result =
      fetch_all(db, "SELECT mount FROM mounts WHERE json_extract(mount, '$.container_id') = ?", [
        id
      ])

    [] =
      fetch_all(db, "DELETE FROM mounts WHERE json_extract(mount, '$.container_id') = ?;", [id])

    result
  end

  def remove_mounts_transaction(db, %Schemas.Volume{name: name}) do
    result =
      fetch_all(db, "SELECT mount FROM mounts WHERE json_extract(mount, '$.source') = ?", [
        name
      ])

    [] = fetch_all(db, "DELETE FROM mounts WHERE json_extract(mount, '$.source') = ?;", [name])

    result
  end

  @spec to_db(
          Schemas.Image.t()
          | Schemas.Container.t()
          | %Schemas.Volume{}
          | %Schemas.MountPoint{}
        ) ::
          String.t()
  defp to_db(struct) do
    map = Map.from_struct(struct)

    case struct.__struct__ do
      Schemas.Image ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Network ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Container ->
        {id, map} = Map.pop(map, :id)
        {:ok, json} = Jason.encode(map)
        {id, json}

      Schemas.Volume ->
        {name, map} = Map.pop(map, :name)
        {:ok, json} = Jason.encode(map)
        {name, json}

      type when type == Schemas.MountPoint or type == Schemas.EndPoint ->
        {:ok, json} = Jason.encode(map)
        json
    end
  end

  @spec from_db(keyword() | {:ok, keyword()}) :: [%Schemas.Image{}]
  defp from_db({:ok, rows}) do
    from_db(rows)
  end

  defp from_db(rows) do
    rows |> Enum.map(&transform_row(&1))
  end

  @spec transform_row(List.t()) :: %Schemas.Image{}
  def transform_row(row) do
    cond do
      Keyword.has_key?(row, :image) ->
        map = from_json(row, :image)
        id = Keyword.get(row, :id)
        struct(Schemas.Image, Map.put(map, :id, id))

      Keyword.has_key?(row, :network) ->
        map = from_json(row, :network)
        id = Keyword.get(row, :id)
        struct(Schemas.Network, Map.put(map, :id, id))

      Keyword.has_key?(row, :container) ->
        map = from_json(row, :container)
        id = Keyword.get(row, :id)
        container = struct(Schemas.Container, Map.put(map, :id, id))
        pub_ports = Enum.map(container.public_ports, &struct(Schemas.PublicPort, &1))
        %Schemas.Container{container | public_ports: pub_ports}

      Keyword.has_key?(row, :volume) ->
        map = from_json(row, :volume)
        name = Keyword.get(row, :name)
        struct(Schemas.Volume, Map.put(map, :name, name))

      Keyword.has_key?(row, :mount) ->
        struct(Schemas.MountPoint, from_json(row, :mount))

      Keyword.has_key?(row, :config) ->
        struct(Schemas.EndPoint, from_json(row, :config))

      Keyword.has_key?(row, :container_id) ->
        Keyword.get(row, :container_id)

      Keyword.has_key?(row, :network_id) ->
        Keyword.get(row, :network_id)

      true ->
        row
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

  def drop_tables(db) do
    {:ok, []} = Sqlitex.query(db, "DROP VIEW api_list_containers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE images")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE containers")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE volumes")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE mounts")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE networks")
    {:ok, []} = Sqlitex.query(db, "DROP TABLE endpoint_configs")
  end

  def create_tables(db) do
    {:ok, []} = Sqlitex.query(db, @table_network)
    {:ok, []} = Sqlitex.query(db, @table_endpoint_configs)
    {:ok, []} = Sqlitex.query(db, @table_images)
    {:ok, []} = Sqlitex.query(db, @table_containers)
    {:ok, []} = Sqlitex.query(db, @table_volumes)
    {:ok, []} = Sqlitex.query(db, @table_mounts)
    {:ok, []} = Sqlitex.query(db, @view_api_list_containers)
  end
end
