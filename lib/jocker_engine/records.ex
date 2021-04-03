defmodule Jocker.Engine.Records do
  require Record

  Record.defrecord(:layer,
    id: :none,
    parent_id: :none,
    dataset: :none,
    snapshot: :none,
    mountpoint: :none
  )

  @type layer() ::
          record(:layer,
            id: String.t() | :none,
            dataset: String.t() | :none,
            snapshot: String.t() | :none,
            mountpoint: String.t() | :none
          )

  Record.defrecord(:container,
    id: :none,
    name: :none,
    pid: :none,
    command: :none,
    layer_id: :none,
    image_id: :none,
    user: :none,
    parameters: [],
    created: :none
  )

  @type container() ::
          record(:container,
            id: String.t() | :none,
            name: String.t() | :none,
            pid: pid() | :none,
            command: [String.t()],
            layer_id: String.t(),
            image_id: String.t(),
            user: String.t(),
            parameters: [String.t()],
            created: String.t() | :none
          )

  Record.defrecord(:volume,
    name: "",
    dataset: :none,
    mountpoint: :none,
    created: :none
  )

  @type volume() ::
          record(:volume,
            name: String.t() | :none,
            dataset: String.t() | :none,
            mountpoint: String.t() | :none,
            created: String.t() | :none
          )

  Record.defrecord(:mount,
    container_id: "",
    volume_name: "",
    location: "",
    read_only: false
  )

  @type mount() ::
          record(:mount,
            container_id: String.t(),
            volume_name: String.t(),
            location: String.t(),
            read_only: boolean()
          )
end
