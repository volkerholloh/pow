defmodule Pow do
  @moduledoc false

  alias Pow.Config

  @doc """
  Checks for version requirement in dependencies.
  """
  @spec dependency_vsn_match?(atom(), binary()) :: boolean()
  def dependency_vsn_match?(dep, req) do
    case :application.get_key(dep, :vsn) do
      {:ok, actual} ->
        actual
        |> List.to_string()
        |> Version.match?(req)

      _any ->
        false
    end
  end

  @doc """
  Dispatches a telemetry event.

  This will dispatch an event with `:telemetry`, if `:telemetry` is available.

  You can attach to these event in Pow. Here's a common example of attaching
  loggint to the session lifecycle:

      defmodule MyApp.LogHandler do
        require Logger

        def handle_event([:my_app, :pow, Pow.Plug.Session, :create], _measurements, metadata, _config) do
          Logger.info("[Pow.Plug.Session] Session \#{hash(metadata.session_key)} initiated (user \#{metadata.user.id})")
        end
        def handle_event([:my_app, :pow, Pow.Plug.Session, :renew], _measurements, metadata, _config) do
          Logger.info("[Pow.Plug.Session] Session \#{hash(metadata.previous_session_key)} has rolled to \#{hash(metadata.session_key)} (user \#{metadata.user.id})")
        end
        def handle_event([:my_app, :pow, Pow.Plug.Session, :delete], _measurements, metadata, _config) do
          Logger.info("[Pow.Plug.Session] Session \#{hash(metadata.session_key)} has been terminated")
        end

        defp hash(session_id) do
          salt = Application.get_env(:my_app, :hash_salt)

          :crypto.hash(:sha256, [session_id, salt]) |> Base.encode16
        end
      end

      events = [
        [:my_app, :pow, Pow.Plug.Session, :create],
        [:my_app, :pow, Pow.Plug.Session, :renew],
        [:my_app, :pow, Pow.Plug.Session, :delete]
      ]
      :telemetry.attach_many("log-handler", events, &MyApp.LogHandler.handle_event/4, nil)
  """
  @spec telemetry_event(Config.t(), module(), atom(), map(), map()) :: :ok
  def telemetry_event(config, module, event_name, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      event_name =
        config
        |> Pow.Config.get(:otp_app)
        |> telemetry_event_name(module, event_name)

      :telemetry.execute(event_name, measurements, metadata)
    end
  end

  defp telemetry_event_name(nil, module, event_name), do: [:pow, module, event_name]
  defp telemetry_event_name(otp_app, module, event_name), do: [otp_app, :pow, module, event_name]
end
