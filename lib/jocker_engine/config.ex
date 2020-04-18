defmodule Jocker.Engine.Config do
  defmacro zroot, do: "zroot/mindflayer_dev"

  # Default image-snap to use when cloning: '@image'
  defmacro base_layer_dataset, do: "zroot/mindflayer_basejail"
  defmacro base_layer_snapshot, do: "zroot/mindflayer_basejail@image"
  defmacro base_layer_mountpoint, do: "/zroot/mindflayer_basejail"
end
