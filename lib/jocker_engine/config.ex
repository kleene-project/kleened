defmodule Jocker.Engine.Config do
  defmacro zroot, do: "zroot/mindflayer_dev"
  defmacro volume_root, do: "zroot/mindflayer_dev/volumes"

  defmacro metadata_db, do: "/zroot/mindflayer_dev/metadata.sqlite"
  defmacro api_socket, do: "/var/run/jocker.sock"

  # Default image-snap to use when cloning: '@image'
  defmacro base_layer_dataset, do: "zroot/mindflayer_basejail"
  defmacro base_layer_snapshot, do: "zroot/mindflayer_basejail@image"
  defmacro base_layer_mountpoint, do: "/zroot/mindflayer_basejail"
end
