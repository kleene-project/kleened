defmodule Kleened.API.ImageBuild do
  alias OpenApiSpex.{Operation, Schema}
  alias Kleened.API.Schemas
  alias Kleened.Core.{Image, Utils}
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3]

  def open_api_operation(_) do
    %Operation{
      # tags: ["users"],
      summary: "image build",
      description: "make a description of the websocket endpoint here.",
      operationId: "ImageBuild",
      parameters: [
        parameter(
          :context,
          :query,
          %Schema{type: :string},
          "description here",
          required: true
        ),
        parameter(
          :dockerfile,
          :query,
          %Schema{type: :string},
          "description here",
          required: true
        ),
        parameter(
          :quiet,
          :query,
          %Schema{type: :string},
          "description here",
          required: true
        ),
        parameter(
          :cleanup,
          :query,
          %Schema{type: :string},
          "description here",
          required: true
        ),
        parameter(:buildargs, :query, %Schema{type: :string}, "description here", required: true)
      ],
      responses: %{
        200 => response("no error", "application/json", Schemas.IdMessage),
        404 => response("no such image", "application/json", Schemas.ErrorMessage)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _state) do
    case validate_request(req0) do
      {:ok, state} ->
        {:cowboy_websocket, req0, state, %{idle_timeout: 60000}}

      {:error, msg} ->
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}
    end
  end

  # Called on websocket connection initialization.
  def websocket_init(%{args: args} = state) do
    case Image.build(
           args["context"],
           args["dockerfile"],
           args["tag"],
           Utils.map2envlist(args["buildargs"]),
           args["cleanup"],
           args["quiet"]
         ) do
      {:ok, build_id, pid} ->
        Logger.debug("Building image. Await output.")
        state = state |> Map.put(:build_pid, pid)
        {[{:text, "OK:#{build_id}"}], state}

      {:error, msg} ->
        Logger.info("Error building image. Closing websocket.")
        {[{:text, "ERROR:#{msg}"}, {:close, 1000, "failed to build image"}], state}
    end
  end

  # Ignore messages from the client: No interactive possibility atm.
  def websocket_handle({:text, _message}, state) do
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info(
        {:image_builder, _pid, {:image_build_succesfully, %Schemas.Image{id: id}}},
        state
      ) do
    {[{:close, 1000, "image created with id #{id}"}], state}
  end

  def websocket_info({:image_builder, _pid, {:image_build_failed, reason}}, state) do
    {[{:close, 1000, "image build failed: #{reason}"}], state}
  end

  def websocket_info({:image_builder, _pid, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) when is_binary(msg) do
    {[{:text, msg}], state}
  end

  defp validate_request(req0) do
    default_values = %{
      # 'tag'-parameter is mandatory
      "context" => "./",
      "dockerfile" => "Dockerfile",
      "quiet" => "false",
      "cleanup" => "true",
      "buildargs" => "{}"
    }

    values = Plug.Conn.Query.decode(req0.qs)
    args = Map.merge(default_values, values)

    args =
      case String.downcase(args["quiet"]) do
        "false" ->
          Map.put(args, "quiet", false)

        "true" ->
          Map.put(args, "quiet", true)

        _ ->
          Map.put(args, "quiet", :invalid_arg)
      end

    args =
      case String.downcase(args["cleanup"]) do
        "false" ->
          Map.put(args, "cleanup", false)

        "true" ->
          Map.put(args, "cleanup", true)

        _ ->
          Map.put(args, "cleanup", :invalid_arg)
      end

    {valid_buildargs, args} =
      case Jason.decode(args["buildargs"]) do
        {:ok, buildargs_decoded} ->
          {true, Map.put(args, "buildargs", buildargs_decoded)}

        {:error, error} ->
          {false, Map.put(args, "buildargs", {:error, inspect(error)})}
      end

    cond do
      not Map.has_key?(args, "tag") ->
        msg = "missing argument tag"
        {:error, msg}

      not is_boolean(args["quiet"]) ->
        msg = "invalid value to argument 'quiet'"
        {:error, msg}

      not valid_buildargs ->
        {:error, error_msg} = args["buildargs"]
        msg = "could not decode 'buildargs' JSON content: #{error_msg}"
        {:error, msg}

      true ->
        state = %{args: args, request: req0}
        {:ok, state}
    end
  end
end
