defmodule Kleened.Core.Deployment do
  alias Kleened.Core.{MetaData, Utils, ZFS, Const}
  require Logger

  def diff(deploy_spec) do
    Logger.debug("Creating diff on spec #{inspect(deploy_spec)}")

    containers = MetaData.list_containers()

    container_result =
      diff_objects(:container, deploy_spec.containers, containers)

    result = %{
      containers: container_result
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

  defp diff_object(:container, {name, spec_object, host_object}) do
    host_object = Map.from_struct(host_object)

    {image_ident, spec_object} = Map.pop(spec_object, :image)
    {image_name, potential_snapshot} = Utils.decode_snapshot(image_ident)

    {spec_object, image_result} =
      case MetaData.get_image(image_name) do
        :not_found ->
          Logger.debug("image '#{image_name}' not found")
          {spec_object, %{type: :non_existing_image, image_name: image_name}}

        image ->
          case ZFS.info(Const.image_snapshot(image.dataset, potential_snapshot)) do
            %{:exists? => true} ->
              spec_object = Map.put(spec_object, :image_id, image.id)

              spec_object =
                case spec_object.cmd do
                  [] -> %{spec_object | cmd: image.cmd}
                  _ -> spec_object
                end

              spec_object =
                case spec_object.user do
                  "" -> %{spec_object | user: image.user}
                  _ -> spec_object
                end

              {spec_object, []}

            %{:exists? => false} ->
              Logger.debug("image snapshot for '#{image_ident}' could not be found")
              {spec_object, %{type: :non_existing_image_snapshot}}
          end
      end

    # Handle endpoints
    endpoints = MetaData.get_endpoints_from_container(host_object.id)
    {endpoints_spec, spec_object} = Map.pop(spec_object, :endpoints)
    ident2endpoints = endpoints |> Enum.map(&{{&1.container_id, &1.network_id}, &1}) |> Map.new()
    endpoints_result = diff_endpoints(endpoints_spec, host_object.id, ident2endpoints, [])

    # Handle mounts
    mountpoints = MetaData.get_mounts_from_container(host_object.id)
    {mountpoints_spec, spec_object} = Map.pop(spec_object, :mounts)

    ident2mounts =
      mountpoints |> Enum.map(&{{"#{&1.type}:#{&1.source}", &1.destination}, &1}) |> Map.new()

    mountpoints_result = diff_mountpoints(mountpoints_spec, ident2mounts, [])

    # Handle remaining properties
    result_rest =
      Map.keys(spec_object)
      |> Enum.map(&diff_object_property(:container, &1, spec_object[&1], host_object[&1]))

    # Remove all the valid object properties
    result =
      List.flatten([image_result, endpoints_result, mountpoints_result | result_rest])

    {name, result}
  end

  defp diff_object(object_type, {name, spec_object_config, host_object}) do
    host_object = Map.from_struct(host_object)

    result =
      Map.keys(spec_object_config)
      |> Enum.map(&diff_object_property(object_type, &1, spec_object_config[&1], host_object[&1]))

    {name, result}
  end

  defp object_id(:image, image) do
    # FIXME: Incorrect, does not work with Image schema.
    Logger.warning("Not implemented #{inspect(image)}")
    image.tag
  end

  defp object_id(object_type, object)
       when object_type == :container or object_type == :network or object_type == :volume do
    object.name
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

  defp diff_mountpoints([], _ident2mounts, results) do
    List.flatten(results)
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

  defp diff_object_property(_object_type, property, value_spec, value_host) do
    Logger.debug(
      "Validating #{property}: spec #{inspect(value_spec)} host #{inspect(value_host)}"
    )

    case value_spec == value_host do
      true ->
        []

      false ->
        %{type: :not_equal, property: property, value_host: value_host, value_spec: value_spec}
    end
  end
end
