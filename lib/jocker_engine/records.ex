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
end
