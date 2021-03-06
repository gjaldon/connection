defmodule ConnectionTest do
  use ExUnit.Case

  test "init {:ok, state}" do
    fun = fn() -> {:ok, 1} end
    assert {:ok, pid} = Connection.start_link(EvalConn, fun)
    assert Connection.call(pid, :state) === 1
  end

  test "init {:ok, state, timeout}" do
    parent = self()

    fun = fn() ->
      timeout = fn() ->
        send(parent, 1)
        {:noreply, 2}
      end
      {:ok, timeout, 0}
    end
    assert {:ok, _} = Connection.start_link(EvalConn, fun)
    assert_receive 1

  end

  test "init {:ok, state, :hibernate}" do
    fun = fn() ->
      {:ok, 1, :hibernate}
    end
    assert {:ok, pid} = Connection.start_link(EvalConn, fun)
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert Connection.call(pid, :state) === 1
  end

  test "init {:connect, info, state}" do
    parent = self()
    fun = fn() ->
      connect = fn(n) ->
        send(parent, {:connect, n})
        {:ok, n+1}
      end
      {:connect, connect, 1}
    end
    {:ok, _} = Connection.start_link(EvalConn, fun)
    assert_receive {:connect, 1}
  end

  test "init {:backoff, timeout, state}" do
    parent = self()
    fun = fn() ->
      connect = fn() ->
        send(parent, :backoff)
        {:ok, :backed_off}
      end
      {:backoff, 0, connect}
    end
    {:ok, _} = Connection.start_link(EvalConn, fun)
    assert_receive :backoff
  end

  test "init {:backoff, timeout, state, timeout}" do
    parent = self()
    fun = fn() ->
      timeout = fn() ->
        connect = fn() ->
          send(parent, :backoff)
          {:ok, :backed_off}
        end
        send(parent, :timeout)
        {:noreply, connect}
      end
      {:backoff, 20, timeout, 0}
    end
    {:ok, _} = Connection.start_link(EvalConn, fun)
    assert_receive :timeout
    assert_receive :backoff
  end

  test "init {:backoff, timeout, state, :hibernate}" do
    parent = self()
    fun = fn() ->
      connect = fn() ->
        send(parent, :backoff)
        {:ok, :backed_off}
      end
      {:backoff, 150, connect, :hibernate}
    end
    {:ok, pid} = Connection.start_link(EvalConn, fun)
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert_receive :backoff
  end

  test "init :ignore" do
    _ = Process.flag(:trap_exit, true)
    fun = fn() -> :ignore end
    assert Connection.start_link(EvalConn, fun, [name: EvalConn]) === :ignore
    assert Process.whereis(EvalConn) === nil
    assert_receive {:EXIT, _, :normal}
  end

  test "init {:stop, reason}" do
    _ = Process.flag(:trap_exit, true)
    fun = fn() -> {:stop, :normal} end
    assert Connection.start_link(EvalConn, fun,
      [name: {:global, {EvalConn, :stop}}]) === {:error, :normal}
    assert :global.whereis_name({EvalConn, :stop}) === :undefined
    assert_receive {:EXIT, _, :normal}
  end

  test "init exit" do
    _ = Process.flag(:trap_exit, true)
    fun = fn() -> exit(:normal) end
    assert Connection.start_link(EvalConn, fun,
      [name: {:via, :global, {EvalConn, :exit}}]) === {:error, :normal}
    assert :global.whereis_name({EvalConn, :exit}) === :undefined
    assert_receive {:EXIT, _, :normal}
  end

  test "init error" do
    _ = Process.flag(:trap_exit, true)
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
    fun = fn() -> :erlang.raise(:error, :oops, stack) end
    assert Connection.start_link(EvalConn, fun,
      [name: {:global, {EvalConn, :error}}]) === {:error, {:oops, stack}}
    assert :global.whereis_name({EvalConn, :error}) === :undefined
    assert_receive {:EXIT, _, {:oops, ^stack}}
  end

  test "init throw" do
    _ = Process.flag(:trap_exit, true)
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
    fun = fn() -> :erlang.raise(:throw, :oops, stack) end
    assert Connection.start_link(EvalConn, fun,
      [name: {:global, {EvalConn, :throw}}]) ===
        {:error, {{:nocatch, :oops}, stack}}
    assert :global.whereis_name({EvalConn, :throw}) === :undefined
    assert_receive {:EXIT, _, {{:nocatch, :oops}, ^stack}}
  end

  test "handle call {:reply, reply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    fun = fn(_, n) -> {:reply, n, n+1} end
    assert Connection.call(pid, fun) === 1
    assert Connection.call(pid, :state) === 2
  end

  test "handle call {:reply, reply, state, timeout}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(_, n) ->
      timeout = fn() ->
        send(parent, {:timeout, n})
        {:noreply, n+1}
      end
      {:reply, n, timeout, 0}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:timeout, 1}
  end

  test "handle call {:noreply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    fun = fn(from, n) ->
      Connection.reply(from, n)
      {:noreply, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert Connection.call(pid, :state) === 2
  end

  test "handle call {:noreply, state, timeout}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()

    fun = fn(from, n) ->
      timeout = fn() ->
        send(parent, {:timeout, n})
        {:noreply, n+1}
      end
      Connection.reply(from, n)
      {:noreply, timeout, 0}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:timeout, 1}
  end

  test "handle call {:reply, reply, state, :hibernate}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    fun = fn(_, n) -> {:reply, n, n+1, :hibernate} end
    assert Connection.call(pid, fun) === 1
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert Connection.call(pid, :state) === 2
  end

  test "handle call {:noreply, state, :hibernate}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    fun = fn(from, n) ->
      Connection.reply(from, n)
      {:noreply, n+1, :hibernate}
    end
    assert Connection.call(pid, fun) === 1
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert Connection.call(pid, :state) === 2
  end

  test "handle call {:connect, info, reply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(_, n) ->
      connect = fn(m) ->
        send(parent, {:connect, m})
        {:ok, m+1}
      end
      {:connect, connect, n, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:connect, 2}
  end

  test "handle call {:connect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(from, n) ->
      connect = fn(m) ->
        send(parent, {:connect, m})
        {:ok, m+1}
      end
      Connection.reply(from, n)
      {:connect, connect, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:connect, 2}
  end

  test "handle call {:disconnect, info, reply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(_, n) ->
      disconnect = fn(m) ->
        send(parent, {:disconnect, m})
        {:noconnect, m+1}
      end
      {:disconnect, disconnect, n, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:disconnect, 2}
  end

  test "handle call {:disconnect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(from, n) ->
      disconnect = fn(m) ->
        send(parent, {:disconnect, m})
        {:noconnect, m+1}
      end
      Connection.reply(from, n)
      {:disconnect, disconnect, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:disconnect, 2}
  end

  test "handle call {:stop, reason, reply, state}" do
    _ = Process.flag(:trap_exit, true)
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(_, n) ->
      terminate = fn(m) ->
        send(parent, {:terminate, m})
      end
      {:stop, {:shutdown, terminate}, n, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:terminate, 2}
    assert_receive {:EXIT, ^pid, {:shutdown, _}}
  end

  test "handle call {:stop, reason, state}" do
    _ = Process.flag(:trap_exit, true)
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(from, n) ->
      terminate = fn(m) ->
        send(parent, {:terminate, m})
      end
      Connection.reply(from, n)
      {:stop, {:shutdown, terminate}, n+1}
    end
    assert Connection.call(pid, fun) === 1
    assert_receive {:terminate, 2}
    assert_receive {:EXIT, ^pid, {:shutdown, _}}
  end

  test "handle cast {:noreply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      send(parent, n)
      {:noreply, n+1}
    end
    assert Connection.cast(pid, fun) === :ok
    assert_receive 1
    assert Connection.call(pid, :state) == 2
  end

  test "handle cast {:noreply, state, timeout}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      timeout = fn() ->
        send(parent, {:timeout, n+1})
        {:noreply, n+1}
      end
      send(parent, n)
      {:noreply, timeout, 0}
    end
    Connection.cast(pid, fun)
    assert_receive 1
    assert_receive {:timeout, 2}
  end

  test "handle cast {:noreply, state, :hibernate}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      send(parent, n)
      {:noreply, n+1, :hibernate}
    end
    Connection.cast(pid, fun)
    assert_receive 1
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert Connection.call(pid, :state) === 2
  end

  test "handle cast {:connect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      connect = fn(m) ->
        send(parent, {:connect, m})
        {:ok, m+1}
      end
      send(parent, n)
      {:connect, connect, n+1}
    end
    Connection.cast(pid, fun)
    assert_receive 1
    assert_receive {:connect, 2}
  end

  test "handle cast {:disconnect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      disconnect = fn(m) ->
        send(parent, {:disconnect, m})
        {:noconnect, m+1}
      end
      send(parent, n)
      {:disconnect, disconnect, n+1}
    end
    Connection.cast(pid, fun)
    assert_receive 1
    assert_receive {:disconnect, 2}
  end

  test "handle cast {:stop, reason, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    _ = Process.flag(:trap_exit, true)
    parent = self()
    fun = fn(n) ->
      terminate = fn(m) ->
        send(parent, {:terminate, m})
      end
      send(parent, n)
      {:stop, {:shutdown, terminate}, n+1}
    end
    Connection.cast(pid, fun)
    assert_receive 1
    assert_receive {:terminate, 2}
    assert_receive {:EXIT, ^pid, {:shutdown, _}}
  end

  test "handle info {:noreply, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      send(parent, n)
      {:noreply, n+1}
    end
    send(pid, fun)
    assert_receive 1
    assert Connection.call(pid, :state) === 2
  end

  test "handle info {:noreply, state, timeout}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      timeout = fn() ->
        send(parent, {:timeout, n+1})
        {:noreply, n+1}
      end
      send(parent, n)
      {:noreply, timeout, 0}
    end
    send(pid, fun)
    assert_receive 1
    assert_receive {:timeout, 2}
  end

  test "handle info {:noreply, state, :hibernate}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      send(parent, n)
      {:noreply, n+1, :hibernate}
    end
    send(pid, fun)
    assert_receive 1
    :timer.sleep(100)
    assert Process.info(pid, :current_function) ===
      {:current_function, {:erlang, :hibernate, 3}}
    assert Connection.call(pid, :state) === 2
  end

  test "handle info {:connect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      connect = fn(m) ->
        send(parent, {:connect, m})
        {:ok, m+1}
      end
      send(parent, n)
      {:connect, connect, n+1}
    end
    send(pid, fun)
    assert_receive 1
    assert_receive {:connect, 2}
  end

  test "handle info {:disconnect, info, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    parent = self()
    fun = fn(n) ->
      disconnect = fn(m) ->
        send(parent, {:disconnect, m})
        {:noconnect, m+1}
      end
      send(parent, n)
      {:disconnect, disconnect, n+1}
    end
    send(pid, fun)
    assert_receive 1
    assert_receive {:disconnect, 2}
  end

  test "handle info {:stop, reason, state}" do
    {:ok, pid} = Connection.start_link(EvalConn, 1)

    _ = Process.flag(:trap_exit, true)
    parent = self()
    fun = fn(n) ->
      terminate = fn(m) ->
        send(parent, {:terminate, m})
      end
      send(parent, n)
      {:stop, {:shutdown, terminate}, n+1}
    end
    send(pid, fun)
    assert_receive 1
    assert_receive {:terminate, 2}
    assert_receive {:EXIT, ^pid, {:shutdown, _}}
  end
end
