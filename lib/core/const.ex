defmodule Kleened.Core.Const do
  @spec image_snapshot() :: String.t()
  def image_snapshot() do
    "@image"
  end

  @spec image_dataset(String.t()) :: Kleened.Core.ZFS.dataset()
  def image_dataset(image_id) do
    Path.join(Kleened.Core.Config.get("kleene_root"), ["image", "/", image_id])
  end

  @spec image_builder_status_message(integer(), integer(), String.t()) :: String.t()
  def image_builder_status_message(step, nsteps, line) do
    "Step #{step}/#{nsteps} : #{line}"
  end

  @spec image_builder_snapshot_message(Kleened.Core.ZFS.snapshot()) :: String.t()
  def image_builder_snapshot_message(snapshot) do
    "--> Snapshot created: #{snapshot}"
  end
end
