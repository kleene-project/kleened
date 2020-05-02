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
    id: :none,
    name: :none,
    tag: :none,
    layer: :none,
    command: :none,
    user: "root",
    created: :none
  )

  Record.defrecord(:container,
    id: :none,
    name: :none,
    running: false,
    pid: :none,
    command: :none,
    layer: :none,
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
            id: String.t() | :none,
            name: String.t() | :none,
            tag: {String.t(), String.t()},
            layer: layer(),
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
            layer: layer(),
            ip: String.t(),
            image_id: String.t(),
            parameters: [String.t()],
            created: String.t()
          )
end
