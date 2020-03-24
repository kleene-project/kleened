defmodule Jocker.Config do
  defmacro zroot, do: "zroot/mindflayer_dev"

  # Default image-snap to use when cloning: '@image'
  defmacro base_layer_location, do: "zroot/mindflayer_basejail@image"
end
