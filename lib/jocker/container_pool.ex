defmodule Jocker.ContainerPool do
  # Automatically defines child_spec/1
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def create(opts) do
    Supervisor.start_child(__MODULE__, [opts])
  end

  @impl true
  def init(_init_arg) do
    children = [
      %{
        :id => Jocker.Container,
        :start => {Jocker.Container, :create, []}
      }
    ]

    # supervise(children, strategy: :simple_one_for_one)
    Supervisor.init(children, strategy: :simple_one_for_one)
  end
end
