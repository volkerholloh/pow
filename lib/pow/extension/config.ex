defmodule Pow.Extension.Config do
  @moduledoc """
  Configuration helpers for extensions.
  """
  alias Pow.Config

  @doc """
  Fetches the `:extensions` key from the configuration.
  """
  @spec extensions(Config.t()) :: [atom()]
  def extensions(config) do
    Config.get(config, :extensions, [])
  end

  @doc """
  Finds all extensions that has a module matching the provided module list.

  It'll concat the extension atom with the  module list, and return a list of
  all modules that is available in the project.
  """
  @spec discover_modules(Config.t(), [any()]) :: [atom()]
  def discover_modules(config, module_list) do
    config
    |> extensions()
    |> Enum.map(&Module.concat([&1] ++ module_list))
    |> Enum.filter(&Code.ensure_compiled?/1)
  end
end
