defmodule Kleened.Core.Deployment do
  alias Kleened.Core.{MetaData, Utils, ZFS, Const, Config}
  alias Kleened.API.Schemas
  require Logger

  @spec diff(%Schemas.DeploymentConfig{}) :: {:ok, %{}} | {:error, String.t()}
  def diff(deploy_spec) do
    Logger.debug("Creating diff on spec #{inspect(deploy_spec)}")

    containers = MetaData.list_containers()
    container_result = diff_objects(:container, deploy_spec.containers, containers)

    images = MetaData.list_images()
    image_result = diff_objects(:image, deploy_spec.images, images)

    networks = MetaData.list_networks()
    network_result = diff_objects(:network, deploy_spec.networks, networks)

    result = %{
      containers: container_result,
      images: image_result,
      networks: network_result
    }

    Logger.info("Diff result: #{inspect(result)}")

    {:ok, result}
  end

  defp diff_objects(object_type, spec_objects, host_objects) do
    id2host_objects =
      Enum.map(host_objects, &{object_id(object_type, &1), &1}) |> Map.new()

    id2spec_objects =
      Enum.map(spec_objects, &{object_id(object_type, &1), &1}) |> Map.new()

    # Find the objects (container/image/network/volume) that is not on the Kleened host.
    {missing_objects, objects_to_check} =
      determine_missing_objects(id2spec_objects, id2host_objects)

    # Look for differences in objects that exists on the Kleened host.
    differing_objects =
      diff_common_objects(objects_to_check, id2spec_objects, id2host_objects, object_type)

    Map.merge(missing_objects, differing_objects)
  end

  defp determine_missing_objects(id2spec_objects, id2host_objects) do
    objects_in_spec = id2spec_objects |> Map.keys() |> MapSet.new()
    objects_on_host = id2host_objects |> Map.keys() |> MapSet.new()

    # Objects missing from the host:
    missing_objects =
      MapSet.difference(objects_in_spec, objects_on_host)
      |> MapSet.to_list()
      |> Enum.map(&{&1, [%{type: :missing_on_host}]})

    # Objects common with spec and host
    # and thus needs to be checked for differences between spec & host configuration
    spec_and_host = MapSet.intersection(objects_in_spec, objects_on_host)
    {Map.new(missing_objects), MapSet.to_list(spec_and_host)}
  end

  defp diff_common_objects(common_objects, id2spec_objects, id2host_objects, object_type) do
    common_objects
    |> Enum.map(&{&1, id2spec_objects[&1], id2host_objects[&1]})
    |> Enum.map(&diff_object(object_type, &1))
    |> Enum.filter(fn {_name, result} -> result != [] end)
    |> Map.new()
  end

  defp diff_object(:container, {name, container_spec, container}) do
    container = Map.from_struct(container)

    {image_result, container_spec} = verify_container_image(container_spec)
    {endpoints_result, container_spec} = diff_endpoints(container_spec, container)

    # Handle mounts
    {mountpoints_result, container_spec} = diff_mountpoints(container_spec, container)

    # Handle remaining properties
    result_rest =
      Map.keys(container_spec)
      |> Enum.map(&diff_object_property(:container, &1, container_spec[&1], container[&1]))

    # Remove all the valid object properties
    result =
      List.flatten([image_result, endpoints_result, mountpoints_result | result_rest])

    {name, result}
  end

  # Images that are created
  defp diff_object(
         :image,
         {name, %{method: method, zfs_dataset: dataset_spec} = image_spec, image}
       ) do
    # Making a few simple checks:
    # - If there is a origin dataset from which the image was cloned
    # - Checking that the instructions property is empty, meaning it is a base image
    # Consider expanding this to include env == [], user == "root" and cmd == []
    result_instructions =
      case image.instructions == [] do
        true -> []
        false -> %{type: :base_image_nonempty_instructions, image: image_spec.tag}
      end

    dataset_info = ZFS.info(image.dataset)

    parent_dataset =
      case dataset_info.parent_snapshot do
        nil ->
          nil

        snapshot ->
          [dataset, _snap] = String.split(snapshot, "@")
          dataset
      end

    result_dataset =
      case {method, parent_dataset} do
        {"zfs-clone", ^dataset_spec} ->
          []

        {"zfs-clone", dataset_origin} ->
          %{type: :base_image_wrong_dataset_origin, image: image_spec.tag, origin: dataset_origin}

        {_, dataset_origin} when dataset_origin != nil ->
          %{type: :base_image_wrong_dataset_origin, image: image_spec.tag, origin: dataset_origin}

        _ ->
          []
      end

    {name, List.flatten([result_instructions, result_dataset])}
  end

  # Images that are being built
  defp diff_object(:image, {name, _spec_object, _host_object}) do
    # There is nothing we can check, only that it is not a clone. But that doesn't really matter.
    # Requires proper context-handling and/or that the config is saved in the image metadata
    {name, []}
  end

  defp diff_object(object_type, {name, spec_object, host_object}) do
    host_object = Map.from_struct(host_object)
    spec_object = Map.from_struct(spec_object)

    result =
      Map.keys(spec_object)
      |> Enum.map(&diff_object_property(object_type, &1, spec_object[&1], host_object[&1]))
      |> List.flatten()

    {name, result}
  end

  defp object_id(:image, %Schemas.Image{name: name, tag: tag}) do
    "#{name}:#{tag}"
  end

  defp object_id(:image, image) do
    Utils.normalize_nametag(image.tag)
  end

  defp object_id(object_type, object)
       when object_type == :container or object_type == :network or object_type == :volume do
    object.name
  end

  defp verify_container_image(container_spec) do
    {image_ident, container_spec} = Map.pop(container_spec, :image)
    {image_name, potential_snapshot} = Utils.decode_snapshot(image_ident)

    case MetaData.get_image(image_name) do
      :not_found ->
        Logger.debug("image '#{image_name}' not found")
        {%{type: :non_existing_image, image_name: image_name}, container_spec}

      image ->
        case ZFS.info(Const.image_snapshot(image.dataset, potential_snapshot)) do
          %{:exists? => true} ->
            container_spec = Map.put(container_spec, :image_id, image.id)

            container_spec =
              case container_spec.cmd do
                [] -> %{container_spec | cmd: image.cmd}
                _ -> container_spec
              end

            container_spec =
              case container_spec.user do
                "" -> %{container_spec | user: image.user}
                _ -> container_spec
              end

            {[], container_spec}

          %{:exists? => false} ->
            Logger.debug("image snapshot for '#{image_ident}' could not be found")
            {%{type: :non_existing_image_snapshot}, container_spec}
        end
    end
  end

  defp diff_endpoints(container_spec, container) do
    {endpoints_spec, container_spec} = Map.pop(container_spec, :endpoints)

    ident2endpoints =
      MetaData.get_endpoints_from_container(container.id)
      |> Enum.map(&{{&1.container_id, &1.network_id}, &1})
      |> Map.new()

    result = diff_endpoints(endpoints_spec, container.id, ident2endpoints, [])
    {result, container_spec}
  end

  defp diff_endpoints([endpoint_spec | rest], container_id, ident2endpoints, result) do
    Logger.debug("Processing endpoint #{inspect(endpoint_spec)}")

    case MetaData.get_network(endpoint_spec.network) do
      :not_found ->
        diff_result = %{type: :non_existing_network, network: endpoint_spec.network}
        diff_endpoints(rest, container_id, ident2endpoints, [diff_result | result])

      network ->
        case Map.has_key?(ident2endpoints, {container_id, network.id}) do
          true ->
            endpoint = ident2endpoints[{container_id, network.id}] |> Map.from_struct()

            diff_result =
              endpoint_spec
              |> Map.from_struct()
              |> Map.delete(:container)
              |> Map.delete(:network)
              |> Map.to_list()
              |> Enum.reduce([], &diff_endpoint_(&1, &2, endpoint))

            diff_endpoints(rest, container_id, ident2endpoints, [diff_result | result])

          false ->
            diff_result = %{
              type: :not_connected,
              network: endpoint_spec.network,
              container: endpoint_spec.container
            }

            diff_endpoints(rest, container_id, ident2endpoints, [diff_result | result])
        end
    end
  end

  defp diff_endpoints([], _, _, result) do
    List.flatten(result)
  end

  # Either ip_address or ip_address6 atm.
  defp diff_endpoint_({_property, "<auto>"}, interim_results, _endpoint) do
    interim_results
  end

  defp diff_endpoint_({property, value_spec}, interim_results, endpoint) do
    value_host = endpoint[property]
    result = diff_object_property(:endpoint, property, value_spec, value_host)
    [result | interim_results]
  end

  defp diff_mountpoints(container_spec, container) do
    {mountpoints_spec, container_spec} = Map.pop(container_spec, :mounts)

    ident2mounts =
      MetaData.get_mounts_from_container(container.id)
      |> Enum.map(&{{"#{&1.type}:#{&1.source}", &1.destination}, &1})
      |> Map.new()

    mountpoints_result = diff_mountpoints(mountpoints_spec, ident2mounts, [])
    {mountpoints_result, container_spec}
  end

  defp diff_mountpoints([mountpoint_spec | rest], ident2mounts, results) do
    # Checking equal source + destination
    with :ok <- volume_exists?(mountpoint_spec),
         :correct_mountpoint_not_found <-
           mountpoint_with_correct_type_source_destination?(mountpoint_spec, ident2mounts),
         :mountpoints_with_equal_source_or_dest <-
           mountpoint_with_equal_source_or_destination?(mountpoint_spec, ident2mounts) do
      Logger.debug("Making diff on mountpoint's source and destination")
      result_unequal_dest = diff_mountpoints_unequal_destination(ident2mounts, mountpoint_spec)
      result_unequal_source = diff_mountpoints_unequal_source(ident2mounts, mountpoint_spec)

      diff_mountpoints(rest, ident2mounts, [
        result_unequal_dest,
        result_unequal_source | results
      ])
    else
      {:correct_mountpoint_found, mountpoint} ->
        Logger.debug("correct mountpoint found #{inspect(mountpoint)}")
        result = check_readonly(mountpoint_spec, mountpoint)
        diff_mountpoints(rest, ident2mounts, [result | results])

      # Checking unequal source + destination
      :no_mountpoints_with_equal_source_or_dest ->
        Logger.debug("no mountpoint found matching either source or destination")

        result = %{
          type: :mount_not_found,
          source: "#{mountpoint_spec.type}:#{mountpoint_spec.source}",
          destination: mountpoint_spec.destination
        }

        diff_mountpoints(rest, ident2mounts, [result | results])

      :volume_not_found ->
        Logger.debug("mountpoint volume not found")
        result = %{type: :mounted_volume_not_found, volume_name: mountpoint_spec.source}
        diff_mountpoints(rest, ident2mounts, [result | results])
    end
  end

  defp diff_mountpoints([], _ident2mounts, results) do
    List.flatten(results)
  end

  defp mountpoint_with_equal_source_or_destination?(mountpoint_spec, ident2mounts) do
    all_unequal =
      ident2mounts
      |> Map.values()
      |> Enum.map(
        &(typed_source(mountpoint_spec) == typed_source(&1) or
            mountpoint_spec.destination == &1.destination)
      )
      |> Enum.any?()

    case all_unequal do
      false -> :no_mountpoints_with_equal_source_or_dest
      true -> :mountpoints_with_equal_source_or_dest
    end
  end

  defp check_readonly(mountpoint_spec, mountpoint) do
    case mountpoint_spec.read_only == mountpoint.read_only do
      true ->
        []

      false ->
        [
          %{
            type: :mount_readonly_diff,
            source: typed_source(mountpoint_spec),
            destination: mountpoint_spec.destination
          }
        ]
    end
  end

  defp volume_exists?(%{type: "volume", source: volume_name}) do
    case MetaData.get_volume(volume_name) do
      :not_found -> :volume_not_found
      _ -> :ok
    end
  end

  defp volume_exists?(_) do
    :ok
  end

  defp mountpoint_with_correct_type_source_destination?(mountpoint_spec, ident2mounts) do
    typed_source_spec = typed_source(mountpoint_spec)
    ident = {typed_source_spec, mountpoint_spec.destination}

    case Map.has_key?(ident2mounts, ident) do
      true ->
        mountpoint = ident2mounts[ident]
        {:correct_mountpoint_found, mountpoint}

      false ->
        :correct_mountpoint_not_found
    end
  end

  defp typed_source(mountpoint) do
    "#{mountpoint.type}:#{mountpoint.source}"
  end

  defp diff_mountpoints_unequal_destination(ident2mounts, mountpoint_spec) do
    typed_source_spec = typed_source(mountpoint_spec)

    ident2mounts
    |> Map.to_list()
    |> Enum.filter(fn {{typed_source, _dst}, _mount} ->
      typed_source == typed_source_spec
    end)
    |> Enum.map(fn {_ident, mount} ->
      %{
        type: :mount_unequal_destination,
        spec_destination: mountpoint_spec.destination,
        host_destination: mount.destination
      }
    end)
  end

  defp diff_mountpoints_unequal_source(ident2mounts, mountpoint_spec) do
    ident2mounts
    |> Map.to_list()
    |> Enum.filter(fn {{_typed_source, dest}, _mount} ->
      dest == mountpoint_spec.destination
    end)
    |> Enum.map(fn {_ident, mount} ->
      %{
        type: :mount_unequal_source,
        spec_source: typed_source(mountpoint_spec),
        host_source: typed_source(mount)
      }
    end)
  end

  defp diff_object_property(:network, :interface, "", _value_host) do
    []
  end

  defp diff_object_property(:network, :nat, "<host-gateway>" = value_spec, value_host) do
    case value_host == Config.get("host_gateway") do
      true ->
        []

      false ->
        %{type: :not_equal, property: "nat", value_spec: value_spec, value_host: value_host}
    end
  end

  defp diff_object_property(object_type, property, value_spec, value_host) do
    Logger.debug(
      "Validating #{object_type}.#{property}: spec #{inspect(value_spec)} host #{inspect(value_host)}"
    )

    case value_spec == value_host do
      true ->
        []

      false ->
        %{type: :not_equal, property: property, value_host: value_host, value_spec: value_spec}
    end
  end
end
