defmodule Kleened.Core.Const do
  def image_snapshot(dataset, "") do
    "#{dataset}@image"
  end

  def image_snapshot(dataset, snapshot) do
    "#{dataset}#{snapshot}"
  end

  def image_snapshot(dataset) do
    "#{dataset}@image"
  end

  def image_dataset(image_id) do
    Path.join(Kleened.Core.Config.get("kleene_root"), ["image", "/", image_id])
  end

  def image_builder_status_message(step, nsteps, line) do
    "Step #{step}/#{nsteps} : #{line}"
  end

  def image_builder_snapshot_message(snapshot) do
    "--> Snapshot created: #{snapshot}"
  end
end
