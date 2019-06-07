defmodule Pow.Store.Backend.EtsCacheTest do
  use ExUnit.Case
  doctest Pow.Store.Backend.EtsCache

  alias Pow.{Config, Store.Backend.EtsCache}

  @default_config [namespace: "pow:test", ttl: :timer.hours(1)]

  setup do
    pid    = self()
    events = [
      [:pow, EtsCache, :cache],
      [:pow, EtsCache, :delete],
      [:pow, EtsCache, :invalidate]
    ]

    :telemetry.attach_many("event-handler-#{inspect pid}", events, fn event, measurements, metadata, send_to: pid ->
      send(pid, {:event, event, measurements, metadata})
    end, send_to: pid)
  end

  test "can put, get and delete records" do
    assert EtsCache.get(@default_config, "key") == :not_found

    EtsCache.put(@default_config, "key", "value")
    assert_receive {:event, [:pow, EtsCache, :cache], _measurements, %{key: "key", value: "value"}}
    assert EtsCache.get(@default_config, "key") == "value"

    EtsCache.delete(@default_config, "key")
    assert_receive {:event, [:pow, EtsCache, :delete], _measurements, %{key: "key"}}
    assert EtsCache.get(@default_config, "key") == :not_found
  end

  test "with no `:ttl` option" do
    config = [namespace: "pow:test"]

    EtsCache.put(config, "key", "value")
    :timer.sleep(100)
    assert EtsCache.get(config, "key") == "value"

    EtsCache.delete(config, "key")
    :timer.sleep(100)
  end

  test "fetch keys" do
    EtsCache.put(@default_config, "key1", "value")
    EtsCache.put(@default_config, "key2", "value")
    :timer.sleep(100)

    assert Enum.sort(EtsCache.keys(@default_config)) == ["key1", "key2"]
  end

  test "records auto purge" do
    config = Config.put(@default_config, :ttl, 100)

    EtsCache.put(config, "key", "value")
    :timer.sleep(50)
    assert EtsCache.get(config, "key") == "value"
    assert_receive {:event, [:pow, EtsCache, :invalidate], _measurements, %{key: "key"}}
    assert EtsCache.get(config, "key") == :not_found
  end
end
