defmodule Pow.Store.Backend.MnesiaCache do
  @moduledoc """
  GenServer based key value Mnesia cache store with auto expiration.

  When the MnesiaCache starts, it'll initialize invalidators for all stored
  keys using the `expire` value. If the `expire` datetime is past, it'll
  send call the invalidator immediately.

  ## Distribution

  The MnesiaCache is built to handle multi-node setup.

  If you initialize with `extra_db_nodes: Node.list()`, it'll automatically
  connect to the cluster. If there is no other nodes available, the data
  persisted to disk will be loaded, but if a cluster is running, the persisted
  data (if any) will be purged on initialization, and the data from the cluster
  will be loaded to the server.

  When a cache key expires, the expiration will be verified before deletion to
  ensure that it hasn't been updated by another node. When a key is updated on
  a node, the node will ping all other nodes to refresh their invalidators so
  the new TTL is used.

  All nodes spun up will by default persist to disk. If you run multiple nodes
  from the same directory you should make sure that each node has a separate
  dir path configured. This can be done using different config files, or by
  using system environment variables:

      config :mnesia, dir: System.get_env("MNESIA_DIR")

  ## Initialization options

    * `:nodes` - list of nodes to use. This value defaults to `[node()]`.

    * `:extra_db_nodes` - list of nodes in cluster to connect to.

    * `:table_opts` - options to add to table definition. This value defaults
      to `[disc_copies: nodes]`.

    * `:timeout` - timeout value in milliseconds for how long to wait until the
      cache table has initiated. Defaults to 15 seconds.

  ## Configuration options

    * `:ttl` - integer value in milliseconds for ttl of records (required).

    * `:namespace` - string value to use for namespacing keys, defaults to
      "cache".
  """
  use GenServer
  alias Pow.{Config, Store.Base}

  require Logger

  @behaviour Base
  @mnesia_cache_tab __MODULE__

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Base
  @spec put(Config.t(), binary(), any()) :: :ok
  def put(config, key, value) do
    GenServer.cast(__MODULE__, {:cache, config, key, value, ttl(config)})
  end

  @impl Base
  @spec delete(Config.t(), binary()) :: :ok
  def delete(config, key) do
    GenServer.cast(__MODULE__, {:delete, config, key})
  end

  @impl Base
  @spec get(Config.t(), binary()) :: any() | :not_found
  def get(config, key) do
    table_get(config, key)
  end

  @impl Base
  @spec keys(Config.t()) :: [any()]
  def keys(config) do
    table_keys(config)
  end

  # Callbacks

  @impl GenServer
  @spec init(Config.t()) :: {:ok, map()}
  def init(config) do
    init_mnesia(config)

    {:ok, %{invalidators: init_invalidators(config)}}
  end

  @impl GenServer
  @spec handle_cast({:cache, Config.t(), binary(), any(), integer()}, map()) :: {:noreply, map()}
  def handle_cast({:cache, config, key, value, ttl}, %{invalidators: invalidators} = state) do
    table_update(config, key, value, ttl)

    invalidators = update_invalidators(config, invalidators, key, ttl)
    refresh_invalidators_in_cluster(config)

    {:noreply, %{state | invalidators: invalidators}}
  end

  @spec handle_cast({:delete, Config.t(), binary()}, map()) :: {:noreply, map()}
  def handle_cast({:delete, config, key}, %{invalidators: invalidators} = state) do
    invalidators = clear_invalidator(invalidators, key)
    table_delete(config, key)

    {:noreply, %{state | invalidators: invalidators}}
  end

  @spec handle_cast({:refresh_invalidators, Config.t()}, map()) :: {:noreply, map()}
  def handle_cast({:refresh_invalidators, config}, %{invalidators: invalidators} = state) do
    clear_invalidators(invalidators)

    {:noreply, %{state | invalidators: init_invalidators(config)}}
  end

  @impl GenServer
  @spec handle_info({:invalidate, Config.t(), binary()}, map()) :: {:noreply, map()}
  def handle_info({:invalidate, config, key}, %{invalidators: invalidators} = state) do
    invalidators = clear_invalidator(invalidators, key)
    invalidators =
      config
      |> fetch(key)
      |> delete_or_reschedule(config, invalidators)

    {:noreply, %{state | invalidators: invalidators}}
  end

  defp delete_or_reschedule(nil, _config, invalidators), do: invalidators
  defp delete_or_reschedule({key, _value, key_config, expire}, config, invalidators) do
    case Enum.max([expire - timestamp(), 0]) do
      0 ->
        table_delete(config, key)

        invalidators
      ttl ->
        update_invalidators(key_config, invalidators, key, ttl)
    end
  end

  defp update_invalidators(config, invalidators, key, ttl) do
    invalidators = clear_invalidator(invalidators, key)
    invalidator  = trigger_ttl(config, key, ttl)

    Map.put(invalidators, key, invalidator)
  end

  defp refresh_invalidators_in_cluster(config) do
    :running_db_nodes
    |> :mnesia.system_info()
    |> Enum.reject(& &1 == node())
    |> Enum.each(&:rpc.call(&1, GenServer, :cast, [__MODULE__, {:refresh_invalidators, config}]))
  end

  defp clear_invalidators(invalidators) do
    Enum.reduce(invalidators, invalidators, fn {key, _ref}, invalidators ->
      clear_invalidator(invalidators, key)
    end)
  end

  defp clear_invalidator(invalidators, key) do
    case Map.get(invalidators, key) do
      nil         -> nil
      invalidator -> Process.cancel_timer(invalidator)
    end

    Map.drop(invalidators, [key])
  end

  defp table_get(config, key) do
    config
    |> fetch(key)
    |> case do
      {_key, value, _config, _expire} -> value
      nil                             -> :not_found
    end
  end

  defp fetch(config, key) do
    mnesia_key = mnesia_key(config, key)

    {@mnesia_cache_tab, mnesia_key}
    |> :mnesia.dirty_read()
    |> case do
      [{@mnesia_cache_tab, ^mnesia_key, {_key, value, config, expire}} | _rest] -> {key, value, config, expire}
      [] -> nil
    end
  end

  defp table_update(config, key, value, ttl) do
    mnesia_key = mnesia_key(config, key)
    expire     = timestamp() + ttl
    value      = {key, value, config, expire}

    :mnesia.sync_transaction(fn ->
      :mnesia.write({@mnesia_cache_tab, mnesia_key, value})
    end)
  end

  defp table_delete(config, key) do
    mnesia_key = mnesia_key(config, key)

    :mnesia.sync_transaction(fn ->
      :mnesia.delete({@mnesia_cache_tab, mnesia_key})
    end)
  end

  defp table_keys(config, opts \\ []) do
    namespace = mnesia_key(config, "")

    sync_all_keys()
    |> Enum.filter(&String.starts_with?(&1, namespace))
    |> maybe_remove_namespace(namespace, opts)
  end

  defp sync_all_keys() do
    {:atomic, keys} = :mnesia.sync_transaction(fn ->
      :mnesia.all_keys(@mnesia_cache_tab)
    end)

    keys
  end

  defp maybe_remove_namespace(keys, namespace, opts) do
    case Keyword.get(opts, :remove_namespace, true) do
      true ->
        start = String.length(namespace)
        Enum.map(keys, &String.slice(&1, start..-1))

      _ ->
        keys
    end
  end

  defp init_mnesia(config) do
    config
    |> find_active_cluster_nodes()
    |> case do
      []    -> init_cluster(config)
      nodes -> join_cluster(config, nodes)
    end
  end

  defp find_active_cluster_nodes(config) do
    visible_nodes = Node.list()
    db_nodes      = Config.get(config, :extra_db_nodes, [])

    db_nodes
    |> Enum.filter(& &1 in visible_nodes)
    |> Enum.filter(&:rpc.block_call(&1, :mnesia, :system_info, [:is_running]) == :yes)
  end

  defp init_cluster(config) do
    nodes = nodes(config)

    with :ok <- start_mnesia(nodes),
         :ok <- change_table_copy_type(config, nodes),
         :ok <- create_table(config, nodes),
         :ok <- wait_for_table(config) do

      Logger.info("[#{inspect __MODULE__}] Mnesia cluster initiated on #{inspect nodes}")
    else
      {:error, reason} ->
        Logger.error("[inspect __MODULE__}] Couldn't initialize node because: #{inspect reason}")
        {:error, reason}
    end
  end

  defp join_cluster(config, cluster_nodes) do
    nodes = nodes(config)

    with :ok <- reset_mnesia(nodes, cluster_nodes),
         :ok <- connect_to_cluster(nodes, cluster_nodes),
         :ok <- change_table_copy_type(config, nodes),
         :ok <- sync_table(config, nodes, cluster_nodes),
         :ok <- wait_for_table(config) do

      Logger.info("[#{inspect __MODULE__}] Joined cluster nodes #{inspect cluster_nodes} for #{inspect nodes}")

      :ok
    else
      {:error, reason} ->
        Logger.error("[inspect __MODULE__}] Couldn't join cluster because: #{inspect reason}")
        {:error, reason}
    end
  end

  defp nodes(config), do: Config.get(config, :nodes, [node()])

  defp start_mnesia(nodes) when is_list(nodes) do
    Enum.each(nodes, &:ok = start_mnesia(&1))
  end
  defp start_mnesia(node) do
    node
    |> block_call(Application, :start, [:mnesia])
    |> case do
      {:error, {:already_started, :mnesia}} -> :ok
      :ok                                   -> :ok
    end
  end

  defp reset_mnesia(nodes, cluster_nodes) when is_list(nodes) do
    Enum.each(nodes, &:ok = reset_mnesia(&1, cluster_nodes))
  end
  defp reset_mnesia(node, [cluster_node | _rest]) do
    block_call(node, Application, :stop, [:mnesia])

    :ok = block_call(node, :mnesia, :delete_schema, [[node]])
    {:atomic, :ok} = block_call(cluster_node, :mnesia, :del_table_copy, [:schema, node])

    start_mnesia(node)

    :ok
  end

  defp change_table_copy_type(config, nodes) when is_list(nodes) do
    Enum.each(nodes, &:ok = change_table_copy_type(config, &1))
  end
  defp change_table_copy_type(config, node) do
    copy_type = get_copy_type(config, node)

    case :mnesia.change_table_copy_type(:schema, node, copy_type) do
      {:atomic, :ok}                               -> :ok
      {:aborted, {:already_exists, :schema, _, _}} -> :ok
    end
  end

  defp get_copy_type(config, node) do
    types      = [:ram_copies, :disc_copies, :disc_only_copies]
    table_opts = Config.get(config, :table_opts, [])

    Enum.find(types, :disc_copies, fn type ->
      nodes = table_opts[type] || []

      node in nodes
    end)
  end

  defp create_table(config, nodes) do
    table_opts = Config.get(config, :table_opts, [disc_copies: nodes])
    table_def  = Keyword.merge(table_opts, [type: :set])

    case :mnesia.create_table(@mnesia_cache_tab, table_def) do
      {:atomic, :ok}                                   -> :ok
      {:aborted, {:already_exists, @mnesia_cache_tab}} -> :ok
    end
  end

  defp sync_table(config, nodes, cluster_nodes) when is_list(nodes) do
    Enum.each(nodes, &{:atomic, :ok} = sync_table(config, &1, cluster_nodes))
  end
  defp sync_table(_config, node, [cluster_node | _rest]) do
    copy_type = block_call(cluster_node, :mnesia, :table_info, [@mnesia_cache_tab, :storage_type])

    block_call(node, :mnesia, :add_table_copy, [@mnesia_cache_tab, node, copy_type])
  end

  defp block_call(node, module, method, args) do
    this_node = node()

    case node do
      ^this_node -> apply(module, method, args)
      node       -> :rpc.block_call(node, module, method, args)
    end
  end

  defp wait_for_table(config) do
    timeout = Config.get(config, :timeout, :timer.seconds(15))

    :mnesia.wait_for_tables([@mnesia_cache_tab], timeout)
  end

  defp connect_to_cluster(nodes, cluster_nodes) when is_list(nodes) do
    Enum.each(nodes, &:ok = connect_to_cluster(&1, cluster_nodes))
  end
  defp connect_to_cluster(node, [cluster_node | _cluster_nodes]) do
    node
    |> block_call(:mnesia, :change_config, [:extra_db_nodes, [cluster_node]])
    |> case do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mnesia_key(config, key) do
    namespace = Config.get(config, :namespace, "cache")

    "#{namespace}:#{key}"
  end

  defp init_invalidators(config) do
    config
    |> table_keys(remove_namespace: false)
    |> Enum.map(&init_invalidator(config, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp init_invalidator(_config, key) do
    {@mnesia_cache_tab, key}
    |> :mnesia.dirty_read()
    |> case do
      [{@mnesia_cache_tab, ^key, {_key_id, _value, _config, nil}} | _rest] ->
        nil

      [{@mnesia_cache_tab, ^key, {key_id, _value, config, expire}} | _rest] ->
        ttl = Enum.max([expire - timestamp(), 0])

        {key, trigger_ttl(config, key_id, ttl)}

      [] -> nil
    end
  end

  defp trigger_ttl(config, key, ttl) do
    Process.send_after(self(), {:invalidate, config, key}, ttl)
  end

  defp timestamp, do: :os.system_time(:millisecond)

  defp ttl(config) do
    Config.get(config, :ttl) || raise_ttl_error()
  end

  @spec raise_ttl_error :: no_return
  defp raise_ttl_error,
    do: Config.raise_error("`:ttl` configuration option is required for #{inspect(__MODULE__)}")
end
