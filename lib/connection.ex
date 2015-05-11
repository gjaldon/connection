defmodule Connection do

  use Behaviour
  @behaviour :gen_server

  defcallback init(any) ::
    {:ok, any} |
    {:ok, any, timeout | :hibernate | :connect | :handshake | :disconnect} |
    :ignore | {:stop, any}

  defcallback handle_connect(any) ::
    {:ok, any} |
    {:ok, any, timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:stop, any, any}

  defcallback handle_handshake(any) ::
    {:ok, any} |
    {:ok, any, timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:stop, any, any}

  defcallback handle_disconnect(any) ::
    {:ok, any} |
    {:ok, any, timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:stop, any, any}

  defcallback handle_call(any, {pid, any}, any) ::
    {:reply, any, any} |
    {:reply, any, any,
      timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:noreply, any} |
    {:noreply, any,
      timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:stop, any, any} | {:stop, any, any, any}

  defcallback handle_info(any, any) ::
    {:noreply, any} |
    {:noreply, any,
      timeout | :hibernate | :connect | :handshake | :disconnect} |
    {:stop, any, any}

  defcallback code_change(any, any, any) :: {:ok, any}

  defcallback terminate(any, any) :: any

  def start_link(mod, args, opts \\ []) do
    start(mod, args, opts, :link)
  end

  def start(mod, args, opts \\ []) do
    start(mod, args, opts, :nolink)
  end

  defdelegate call(conn, req), to: :gen_server

  defdelegate call(conn, req, timeout), to: :gen_server

  defdelegate cast(conn, req), to: :gen_server

  defdelegate reply(from, response), to: :gen_server

  ## :gen callback

  @doc false
  def init_it(starter, _, name, mod, args, opts) do
    Process.put(:"$initial_call", {mod, :init, 1})
    try do
      apply(mod, :init, [args])
    catch
      :exit, reason ->
        init_stop(starter, name, reason)
      :error, reason ->
        init_stop(starter, name, {reason, System.stacktrace()})
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        init_stop(starter, name, reason)
    else
      {:ok, mod_state} ->
        :proc_lib.init_ack(starter, {:ok, self()})
        enter_loop(mod, mod_state, name, opts, :infinity)
      {:ok, mod_state, info} ->
        :proc_lib.init_ack(starter, {:ok, self()})
        enter_loop(mod, mod_state, name, opts, info)
      :ignore ->
        _ = unregister(name)
        :proc_lib.init_ack(starter, :ignore)
        exit(:normal)
      {:stop, reason} ->
        init_stop(starter, name, reason)
      other ->
        init_stop(starter, name, {:bad_return_value, other})
    end
  end

  ## :proc_lib callback

  @doc false
  def enter_loop(mod, mod_state, name, opts, :hibernate) do
    args = [mod, mod_state, name, opts, :infinity]
    :proc_lib.hibernate(__MODULE__, :enter_loop, args)
  end
  def enter_loop(mod, mod_state, name, opts, :connect) do
    enter_callback(mod, :handle_connect, mod_state, name, opts)
  end
  def enter_loop(mod, mod_state, name, opts, :handshake) do
    enter_callback(mod, :handle_handshake, mod_state, name, opts)
  end
  def enter_loop(mod, mod_state, name, opts, :disconnect) do
    enter_callback(mod, :handle_disconnect, mod_state, name, opts)
  end
  def enter_loop(mod, mod_state, name, opts, timeout) when name === self() do
    :gen_server.enter_loop(__MODULE__, opts, {mod, mod_state}, timeout)
  end
  def enter_loop(mod, mod_state, name, opts, timeout) do
    :gen_server.enter_loop(__MODULE__, opts, {mod, mod_state}, name, timeout)
  end

  @doc false
  def init(_) do
    {:stop, __MODULE__}
  end

  @doc false
  def handle_call(request, from, {mod, mod_state}) do
    try do
      apply(mod, :handle_call, [request, from, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, System.stacktrace())
    else
      {:noreply, mod_state} ->
        loop(mod, mod_state, :infinity)
      {:noreply, mod_state, info} ->
        loop(mod, mod_state, info)
      {:reply, reply, mod_state} ->
        :gen_server.reply(from, reply)
        loop(mod, mod_state, :infinity)
      {:reply, reply, mod_state, info} ->
        :gen_server.reply(from, reply)
        loop(mod, mod_state, info)
      {:stop, _, mod_state} = stop ->
        put_elem(stop, 2, {mod, mod_state})
      {:stop, _, _, mod_state} = stop ->
        put_elem(stop, 3, {mod, mod_state})
      other ->
        {:stop, {:bad_return_value, other}, {mod, mod_state}}
    end
  end

  @doc false
  def handle_cast(request, {mod, mod_state}) do
    handle_async(mod, mod_state, :handle_cast, request)
  end

  @doc false
  def handle_info(msg, {mod, mod_state}) do
    handle_async(mod, mod_state, :handle_info, msg)
  end

  @doc false
  def code_change(old_vsn, {mod, mod_state}, extra) do
    try do
      apply(mod, :code_change, [old_vsn, mod_state, extra])
    catch
      :throw, value ->
        exit({{:nocatch, value}, System.stacktrace()})
    else
      {:ok, mod_state} ->
        {:ok, {mod, mod_state}}
    end
  end

  @doc false
  def format_status(:normal, [pdict, {mod, mod_state}]) do
    try do
      apply(mod, :format_status, [:normal, [pdict, mod_state]])
    catch
      _, _ ->
        [{:data, [{'State', mod_state}]}]
    else
      mod_status ->
        mod_status
    end
  end
  def format_status(:terminate, [pdict, {mod, mod_state}]) do
    try do
      apply(mod, :format_status, [:terminate, [pdict, mod_state]])
    catch
      _, _ ->
        mod_state
    else
      mod_state ->
        mod_state
    end
  end
  def format_status(:terminate, [pdict, {_, mod, mod_state, _, _}]) do
    format_status(:terminate, [pdict, {mod, mod_state}])
  end

  @doc false
  def terminate(reason, {mod, mod_state}) do
    apply(mod, :terminate, [reason, mod_state])
  end
  def terminate(exit_reason, {kind, mod, mod_state, reason, stack}) do
    try do
      apply(mod, :terminate, [exit_reason, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, System.stacktrace())
    else
      _ ->
        :erlang.raise(kind, reason, stack)
    end
  end

  # start helpers

  defp start(mod, args, options, link) do
    case Keyword.pop(options, :name) do
      {nil, opts} ->
        :gen.start(__MODULE__, link, mod, args, opts)
      {atom, opts} when is_atom(atom) ->
        :gen.start(__MODULE__, link, {:local, atom}, mod, args, opts)
      {{:global, _} = name, opts} ->
        :gen.start(__MODULE__, link, name, mod, args, opts)
      {{:via, _, _} = name, opts} ->
        :gen.start(__MODULE__, link, name, mod, args, opts)
    end
  end

  # init helpers

  defp init_stop(starter, name, reason) do
    _ = unregister(name)
    :proc_lib.init_ack(starter, reason)
    exit(reason)
  end

  defp unregister(name) when name === self(), do: :ok
  defp unregister({:local, name}), do: Process.unregister(name)
  defp unregister({:global, name}), do: :global.unregister_name(name)
  defp unregister({:via, mod, name}), do: apply(mod, :unregister_name, [name])

  ## enter_loop helpers

  defp enter_callback(mod, fun, mod_state, name, opts) do
    try do
      apply(mod, fun, [mod_state])
    catch
      :exit, reason ->
        report_reason = {reason, System.stacktrace()}
        enter_terminate(mod, mod_state, name, reason, report_reason)
      :error, reason ->
        reason = {reason, System.stacktrace()}
        enter_terminate(mod, mod_state, name, reason, reason)
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        enter_terminate(mod, mod_state, name, reason, reason)
    else
      {:ok, mod_state} ->
        enter_loop(mod, mod_state, name, opts, :infinity)
      {:ok, mod_state, info} ->
        enter_loop(mod, mod_state, name, opts, info)
      {:stop, reason, mod_state} ->
        enter_terminate(mod, mod_state, name, reason, reason)
      other ->
        reason = {:bad_return_value, other}
        enter_terminate(mod, mod_state, name, reason, reason)
    end
  end

  defp enter_terminate(mod, mod_state, name, reason, report_reason) do
    try do
      apply(mod, :terminate, [reason, mod_state])
    catch
      :exit, reason ->
        enter_stop(mod, mod_state, name, reason, {reason, System.stacktrace()})
      :error, reason ->
        reason = {reason, System.stacktrace()}
        enter_stop(mod, mod_state, name, reason, reason)
      :throw, value ->
        reason = {{:nocatch, value}, System.stacktrace()}
        enter_stop(mod, mod_state, name, reason, reason)
    else
      _ ->
        enter_stop(mod, mod_state, name, reason, report_reason)
    end
  end

  defp enter_stop(mod, mod_state, name, reason, reason2) do
    mod_state = format_status(:terminate, [Process.get(), {mod, mod_state}])
    format = '** Generic server ~p terminating \n' ++
      '** Last message in was ~p~n' ++ ## No last message
      '** When Server state == ~p~n' ++
      '** Reason for termination == ~n** ~p~n'
    args = [report_name(name), nil, mod_state, report_reason(reason2)]
    :error_logger.format(format, args)
    exit(reason)
  end

  defp report_name(name) when name === self(), do: name
  defp report_name({:local, name}), do: name
  defp report_name({:global, name}), do: name
  defp report_name({:via, _, name}), do: name

  defp report_reason({:undef, [{mod, fun, args, _} | _] = stack} = reason) do
    cond do
      :code.is_loaded(mod) !== false ->
        {:"module could not be loaded", stack}
      not function_exported?(mod, fun, length(args)) ->
        {:"function not exported", stack}
      true ->
        reason
    end
  end
  defp report_reason(reason) do
    reason
  end

  ## GenServer helpers

  defp loop(mod, mod_state, :connect) do
    callback(mod, mod_state, :handle_connect)
  end
  defp loop(mod, mod_state, :handshake) do
    callback(mod, mod_state, :handle_handshake)
  end
  defp loop(mod, mod_state, :disconnect) do
    callback(mod, mod_state, :handle_disconnect)
  end
  defp loop(mod, mod_state, timeout) do
    {:noreply, {mod, mod_state}, timeout}
  end

  defp callback(mod, mod_state, fun) do
    # In order to have new mod_state in terminate/2 must return the exit reason.
    # However to get the correct GenServer report (exit with stacktrace),
    # include stacktrace in state and re-raise after calling mod.terminate/2 if
    # it does not raise. The raise state is formatted in format_status/2 to look
    # like the normal state.
    try do
      apply(mod, fun, [mod_state])
    catch
      :exit, reason ->
        {:stop, reason, {:exit, mod, mod_state, reason, System.stacktrace()}}
      :error, reason ->
        reason2 = {reason, System.stacktrace()}
        {:stop, reason2, {:error, mod, mod_state, reason, System.stacktrace()}}
      :throw, value ->
        reason = {:nocatch, value}
        reason2 = {reason, System.stacktrace()}
        {:stop, reason2, {:error, mod, mod_state, reason, System.stacktrace()}}
    else
      {:ok, mod_state} ->
        loop(mod, mod_state, :infinity)
      {:ok, mod_state, info} ->
        loop(mod, mod_state, info)
      {:stop, _, mod_state} = stop ->
        put_elem(stop, 2, {mod, mod_state})
      other ->
        {:stop, {:bad_return_value, other}, {mod, mod_state}}
    end
  end

  defp handle_async(mod, mod_state, fun, msg) do
    try do
      apply(mod, fun, [msg, mod_state])
    catch
      :throw, value ->
        :erlang.raise(:error, {:nocatch, value}, System.stacktrace())
    else
      {:noreply, mod_state} ->
        loop(mod, mod_state, :infinity)
      {:noreply, mod_state, info} ->
        loop(mod, mod_state, info)
      {:stop, _, mod_state} = stop ->
        put_elem(stop, 2, {mod, mod_state})
      other ->
        {:stop, {:bad_return_value, other}, {mod, mod_state}}
    end
  end
end