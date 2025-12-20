defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.Cache (ETS storage)
  - Nopea.Registry (process name registry)
  - Nopea.Git (Rust Port GenServer)
  - Nopea.Supervisor (DynamicSupervisor for Workers)
  - Nopea.Controller (CRD watcher, optional)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    # ETS cache for commits, resources, sync state
    children =
      if Application.get_env(:nopea, :enable_cache, true) do
        children ++ [Nopea.Cache]
      else
        children
      end

    # Registry for worker name lookup (always needed if supervisor is enabled)
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [{Registry, keys: :unique, name: Nopea.Registry}]
      else
        children
      end

    # Git GenServer (Rust Port)
    children =
      if Application.get_env(:nopea, :enable_git, true) do
        children ++ [Nopea.Git]
      else
        children
      end

    # DynamicSupervisor for Worker processes
    children =
      if Application.get_env(:nopea, :enable_supervisor, true) do
        children ++ [Nopea.Supervisor]
      else
        children
      end

    # Controller (watches GitRepository CRDs)
    children =
      if Application.get_env(:nopea, :enable_controller, true) do
        namespace = Application.get_env(:nopea, :watch_namespace, "default")
        children ++ [{Nopea.Controller, namespace: namespace}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end
end
