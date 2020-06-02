defmodule Jocker.Engine.ContainerPool do
  # Automatically defines child_spec/1
  use Supervisor
  require Logger

  def start_link([]) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def create(opts) do
    case Supervisor.start_child(__MODULE__, [opts]) do
      {:error, {:bad_return_value, {:stop, :normal, msg}}} ->
        msg

      other_return_value ->
        other_return_value
    end
  end

  @impl true
  def init([]) do
    children = [
      %{
        :id => Jocker.Engine.Container,
        :start => {Jocker.Engine.Container, :create, []}
      }
    ]

    Supervisor.init(children, strategy: :simple_one_for_one)
  end
end
