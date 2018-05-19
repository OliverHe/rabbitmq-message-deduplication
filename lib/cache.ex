# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2017-2018, Matteo Cafasso.
# All rights reserved.


defmodule RabbitMQ.MessageDeduplicationPlugin.Cache do
  @moduledoc """
  Simple cache implemented on top of Mnesia.

  Entrys can be stored within the cache with a given TTL.
  After the TTL expires the entrys will be transparently removed.

  The cache does not implement a FIFO mechanism due to Mnesia API limitations.
  An FIFO mechanism could be implemented using ordered_sets
  but performance should be evaluated.

  """

  use GenServer

  alias :os, as: Os
  alias :timer, as: Timer
  alias :mnesia, as: Mnesia

  ## Client API

  @doc """
  Create a new cache and start it.
  """
  @spec start_link(atom, list) :: :ok | { :error, any }
  def start_link(cache, options) do
    GenServer.start_link(__MODULE__, {cache, options}, name: cache)
  end

  @doc """
  Put the given entry into the cache.
  The TTL controls the lifetime in milliseconds of the entry.
  """
  @spec put(atom, any, integer | nil) :: :ok | { :error, any }
  def put(cache, entry, ttl \\ nil) do
    GenServer.call(cache, {:put, cache, entry, ttl})
  end

  @doc """
  Delete the given entry from the cache.
  """
  @spec delete(atom, any) :: :ok | { :error, any }
  def delete(cache, entry) do
    GenServer.call(cache, {:delete, cache, entry})
  end

  @doc """
  True if the entry is contained within the cache.
  """
  @spec delete(atom, any) :: boolean
  def member?(cache, entry) do
    GenServer.call(cache, {:member?, cache, entry})
  end

  @doc """
  Flush the cache content.
  """
  @spec flush(atom) :: :ok | { :error, any }
  def flush(cache) do
    GenServer.call(cache, {:flush, cache})
  end

  @doc """
  Drop the cache with all its content.
  """
  @spec drop(atom) :: :ok | { :error, any }
  def drop(cache) do
    GenServer.call(cache, {:drop, cache})
  end

  @doc """
  Return information related to the given cache.
  """
  @spec drop(atom) :: list
  def info(cache) do
    GenServer.call(cache, {:info, cache})
  end

  ## Server Callbacks

  # Creates the Mnesia table and starts the janitor process.
  def init({cache, options}) do
    Mnesia.start()

    :ok = cache_create(cache, options)

    Process.send_after(cache, {:cache, cache}, Timer.seconds(3))

    {:ok, %{}}
  end

  # The janitor process deletes expired cache entries.
  def handle_info({:cache, cache}, state) do
    {_, result} = cache_delete_expired(cache)
    if (result == :ok) do
      Process.send_after(cache, {:cache, cache}, Timer.seconds(3))
    end

    {:noreply, state}
  end

  # Puts a new entry in the cache.
  # If the cache is full, remove an element to make space.
  def handle_call({:put, cache, entry, ttl}, _from, state) do
    if cache_full?(cache) do
      cache_delete_first(cache)
    end

    Mnesia.transaction(fn ->
      Mnesia.write({cache, entry, entry_expiration(cache, ttl)})
    end)

    {:reply, :ok, state}
  end

  # Removes the given entry from the cache.
  def handle_call({:delete, cache, entry}, _from, state) do
    Mnesia.transaction(fn ->
      Mnesia.delete({cache, entry})
    end)

    {:reply, :ok, state}
  end

  # True if the entry is in the cache.
  def handle_call({:member?, cache, entry}, _from, state) do
    {:reply, cache_member?(cache, entry), state}
  end

  # Flush the Mnesia cache table.
  def handle_call({:flush, cache}, _from, state) do
    case Mnesia.clear_table(cache) do
      {:atomic, :ok} -> {:reply, :ok, state}
      _ -> {:reply, :error, state}
    end
  end

  # Drop the Mnesia cache table.
  def handle_call({:drop, cache}, _from, state) do
    case Mnesia.delete_table(cache) do
      {:atomic, :ok} -> {:reply, :ok, state}
      _ -> {:reply, :error, state}
    end
  end

  # Return cache information: number of elements and max size
  def handle_call({:info, cache}, _from, state) do
    info = [size: cache_property(cache, :limit),
            entries: Mnesia.table_info(cache, :size)]

    {:reply, info, state}
  end

  ## Utility functions

  # Mnesia cache table creation.
  defp cache_create(cache, options) do
    persistence = case Keyword.get(options, :persistence) do
                    :disk -> :disc_copies
                    :memory -> :ram_copies
                  end
    options = [{:attributes, [:entry, :expiration]},
               {persistence, [node()]},
               {:index, [:expiration]},
               {:user_properties, [{:limit, Keyword.get(options, :size)},
                                   {:default_ttl, Keyword.get(options, :ttl)}]}]

    Mnesia.create_table(cache, options)
    Mnesia.add_table_copy(cache, node(), persistence)
    Mnesia.wait_for_tables([cache], Timer.seconds(30))
  end

  # Mnesia cache lookup. The entry is not returned if expired.
  defp cache_member?(cache, entry) do
    {:atomic, entries} = Mnesia.transaction(fn -> Mnesia.read(cache, entry) end)

    case List.keyfind(entries, entry, 1) do
      {_, _, expiration} -> expiration > Os.system_time(:millisecond)
      nil -> false
    end
  end

  # Remove all expired entries from the Mnesia cache.
  defp cache_delete_expired(cache) do
    select = fn ->
      Mnesia.select(cache, [{{cache, :"$1", :"$2"},
                             [{:>, Os.system_time(:millisecond), :"$2"}],
                             [:"$1"]}])
    end

    case Mnesia.transaction(select) do
      {:atomic, expired} ->
        Mnesia.transaction(
          fn ->
            Enum.each(expired, fn e -> Mnesia.delete({cache, e}) end)
          end)
      {:aborted, {:no_exists, _}} -> {:aborted, :no_cache}
    end
  end

  # Delete the first element from the cache.
  # As the Mnesia Set is not ordered, the first element is random.
  defp cache_delete_first(cache) do
    Mnesia.transaction(fn -> Mnesia.delete({cache, Mnesia.first(cache)}) end)
  end

  defp cache_full?(cache) do
    Mnesia.table_info(cache, :size) >= cache_property(cache, :limit)
  end

  # Calculate the expiration given a TTL or the cache default TTL
  defp entry_expiration(cache, ttl) do
    default = cache_property(cache, :default_ttl)

    cond do
      ttl != nil -> Os.system_time(:millisecond) + ttl
      default != nil -> Os.system_time(:millisecond) + default
      true -> nil
    end
  end

  # Retrieve the given property from the Mnesia user_properties field
  defp cache_property(cache, property) do
    {^property, entry} =
      cache
      |> Mnesia.table_info(:user_properties)
      |> Enum.find(fn(element) -> match?({^property, _}, element) end)

    entry
  end
end
