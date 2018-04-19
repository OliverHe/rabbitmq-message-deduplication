defmodule RabbitMQ.CacheSupervisor do
  @moduledoc """
  The Cache Supervisor supervisions the Cache GenServer Processes.
  """

  use DynamicSupervisor

  @doc """
  Start the Supervisor process.
  """
  def start_link() do
    case DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      _ -> :error
    end
  end

  @doc """
  Starts a new cache with the given name and options.
  """
  def start_cache(cache, options) do
    specifications = %{id: cache,
                       start: {RabbitMQ.Cache, :start_link, [cache, options]}}

    case DynamicSupervisor.start_child(__MODULE__, specifications) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :error
    end
  end

  @doc """
  Stops the given cache.
  """
  def stop_cache(cache) do
    DynamicSupervisor.terminate_child(__MODULE__, Process.whereis(cache))
  end

  @doc """
  Supervisor initialization callback.
  """
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
