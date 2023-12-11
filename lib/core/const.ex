defmodule Kleened.Core.Const do
  def image_snapshot() do
    "@image"
  end

  def image_dataset(image_id) do
    Path.join(Kleened.Core.Config.get("zroot"), ["image", "/", image_id])
  end

  def image_builder_status_message(step, nsteps, line) do
    "Step #{step}/#{nsteps} : #{line}\n"
  end

  def image_builder_snapshot_message(snapshot) do
    "--> Snapshot created: #{snapshot}\n"
  end
end
