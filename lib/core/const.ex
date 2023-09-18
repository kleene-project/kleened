defmodule Kleened.Core.Const do
  def image_builder_status_message(step, nsteps, line) do
    "Step #{step}/#{nsteps} : #{line}\n"
  end

  def image_builder_snapshot_message(snapshot) do
    "--> Snapshot created: #{snapshot}\n"
  end
end
