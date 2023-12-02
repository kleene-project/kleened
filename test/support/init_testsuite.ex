defmodule TestInitialization do
  alias Kleened.Core.{MetaData, Container, Image, ImageCreate}
  alias Kleened.API.Schemas

  @creation_time "2023-09-14T21:21:57.990515Z"

  def create_test_base_image() do
    creator_pid =
      ImageCreate.start_image_creation(%Schemas.ImageCreateConfig{
        method: "zfs-clone",
        tag: "FreeBSD:testing",
        zfs_dataset: "zroot/kleene_basejail"
      })

    image = process_image_creator_messages(creator_pid)
    MetaData.add_image(%Schemas.Image{image | created: @creation_time})
    :ok
  end

  defp process_image_creator_messages(creator_pid) do
    receive do
      {:image_creator, ^creator_pid, {:ok, image}} ->
        image

      {:image_creator, ^creator_pid, {:error, error_msg}} ->
        Logger.error("Could not build test base image: #{inspect(error_msg)}")
        Process.exit(self(), :failed_to_build_test_baseimage)
    end
  end

  def clear() do
    MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

    MetaData.list_images()
    |> Enum.filter(fn %Schemas.Image{id: id} -> id != "base" end)
    |> Enum.map(fn %Schemas.Image{id: id} -> Image.destroy(id) end)
  end
end
