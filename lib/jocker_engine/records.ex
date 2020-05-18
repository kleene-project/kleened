defmodule Jocker.Engine.Records do
  require Record

  Record.defrecord(:layer,
    id: :none,
    parent_id: :none,
    dataset: :none,
    snapshot: :none,
    mountpoint: :none
  )

  Record.defrecord(:image,
    id: "",
    name: "",
    tag: "",
    layer_id: "",
    command: [],
    user: "root",
    created: ""
  )

  Record.defrecord(:container,
    id: :none,
    name: :none,
    running: false,
    pid: :none,
    command: :none,
    layer_id: :none,
    ip: :none,
    image_id: :none,
    parameters: [],
    created: :none
  )

  @type layer() ::
          record(:layer,
            id: String.t() | :none,
            dataset: String.t() | :none,
            snapshot: String.t() | :none,
            mountpoint: String.t() | :none
          )

  @type image() ::
          record(:image,
            id: String.t(),
            name: String.t(),
            tag: String.t(),
            layer_id: String.t(),
            command: [String.t()],
            user: String.t(),
            created: String.t()
          )

  @type container() ::
          record(:container,
            id: String.t() | :none,
            name: String.t() | :none,
            running: true | false,
            pid: pid(),
            command: [String.t()],
            layer_id: String.t(),
            ip: String.t(),
            image_id: String.t(),
            parameters: [String.t()],
            created: String.t()
          )
end
