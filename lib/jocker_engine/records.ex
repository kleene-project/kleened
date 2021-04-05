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
end
