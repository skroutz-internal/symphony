defmodule SymphonyElixir.DockerWorkerPool do
  @moduledoc """
  Manages a pool of ephemeral Docker SSH worker containers.

  Reads `worker.docker` from the WORKFLOW.md config, spawns N containers on
  startup (one per worker slot), registers their SSH addresses with
  `Config.set_dynamic_ssh_hosts/1`, and tears them all down on shutdown.

  Each container is started with `--restart always` so that after a run
  completes (the `after_run` hook does `kill 1`), Docker immediately replaces
  it with a fresh container on the same port — ready for the next run.

  ## WORKFLOW.md config

      worker:
        docker:
          image: "my-project-worker:latest"
          n_workers: 2
          base_port: 2222
          ssh_pubkey: "~/.ssh/id_ed25519.pub"
          mounts:
            - host: "~/code/myproject"
              container: "/repos/myproject"
              mode: rw
            - host: "~/.pi/agent"
              container: "/root/.pi/agent"
              mode: ro
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config

  # ---------------------------------------------------------------------------
  # Config structs (owned here to keep diff on schema.ex at zero)
  # ---------------------------------------------------------------------------

  defmodule Mount do
    @moduledoc false
    @enforce_keys [:host, :container]
    defstruct [:host, :container, mode: "ro"]

    @type t :: %__MODULE__{
            host: String.t(),
            container: String.t(),
            mode: String.t()
          }

    @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
    def from_map(%{"host" => host, "container" => container} = m)
        when is_binary(host) and is_binary(container) do
      mode = Map.get(m, "mode", "ro")

      if mode in ["ro", "rw"] do
        {:ok, %__MODULE__{host: Path.expand(host), container: container, mode: mode}}
      else
        {:error, "mount mode must be 'ro' or 'rw', got: #{inspect(mode)}"}
      end
    end

    def from_map(m), do: {:error, "mount missing required 'host' or 'container': #{inspect(m)}"}
  end

  defmodule DockerConfig do
    @moduledoc false
    @enforce_keys [:image]
    defstruct [
      :image,
      n_workers: 1,
      base_port: 2222,
      ssh_pubkey: "~/.ssh/id_ed25519.pub",
      mounts: []
    ]

    @type t :: %__MODULE__{
            image: String.t(),
            n_workers: pos_integer(),
            base_port: pos_integer(),
            ssh_pubkey: String.t(),
            mounts: [Mount.t()]
          }

    @spec from_workflow(map()) :: {:ok, t()} | {:error, String.t()} | :disabled
    def from_workflow(%{"worker" => %{"docker" => docker}}) when is_map(docker) do
      with {:ok, image} <- required_string(docker, "image"),
           {:ok, mounts} <- parse_mounts(Map.get(docker, "mounts", [])) do
        {:ok,
         %__MODULE__{
           image: image,
           n_workers: Map.get(docker, "n_workers", 1),
           base_port: Map.get(docker, "base_port", 2222),
           ssh_pubkey: Path.expand(Map.get(docker, "ssh_pubkey", "~/.ssh/id_ed25519.pub")),
           mounts: mounts
         }}
      end
    end

    def from_workflow(_), do: :disabled

    defp required_string(map, key) do
      case Map.get(map, key) do
        v when is_binary(v) and v != "" -> {:ok, v}
        _ -> {:error, "worker.docker.#{key} is required"}
      end
    end

    defp parse_mounts(list) when is_list(list) do
      Enum.reduce_while(list, {:ok, []}, fn m, {:ok, acc} ->
        case Mount.from_map(m) do
          {:ok, mount} -> {:cont, {:ok, acc ++ [mount]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp parse_mounts(_), do: {:error, "worker.docker.mounts must be a list"}
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct container_ids: [], hosts: []
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec container_ids() :: [String.t()]
  def container_ids do
    GenServer.call(__MODULE__, :container_ids)
  end

  @impl true
  def init(_opts) do
    case load_docker_config() do
      :disabled ->
        Logger.debug("DockerWorkerPool: no worker.docker config found, pool disabled")
        :ignore

      {:ok, docker_config} ->
        Logger.info("DockerWorkerPool: starting #{docker_config.n_workers} worker(s) from image #{docker_config.image}")

        case spawn_workers(docker_config) do
          {:ok, container_ids, hosts} ->
            Config.set_dynamic_ssh_hosts(hosts)
            Logger.info("DockerWorkerPool: workers ready at #{inspect(hosts)}")
            {:ok, %State{container_ids: container_ids, hosts: hosts}}

          {:error, reason} ->
            Logger.error("DockerWorkerPool: failed to spawn workers: #{reason}")
            {:stop, {:docker_worker_pool_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("DockerWorkerPool: invalid config: #{reason}")
        {:stop, {:docker_worker_pool_config_error, reason}}
    end
  end

  @impl true
  def handle_call(:container_ids, _from, state) do
    {:reply, state.container_ids, state}
  end

  @impl true
  def terminate(_reason, %State{container_ids: ids}) when ids != [] do
    Logger.info("DockerWorkerPool: stopping #{length(ids)} container(s)")

    Enum.each(ids, fn id ->
      case System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true) do
        {_, 0} -> Logger.debug("DockerWorkerPool: removed container #{id}")
        {out, code} -> Logger.warning("DockerWorkerPool: failed to remove #{id} (exit #{code}): #{String.trim(out)}")
      end
    end)
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_docker_config do
    case SymphonyElixir.Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        DockerConfig.from_workflow(config)

      {:error, reason} ->
        {:error, "could not load workflow: #{inspect(reason)}"}
    end
  end

  defp spawn_workers(%DockerConfig{} = cfg) do
    pubkey_content =
      case File.read(cfg.ssh_pubkey) do
        {:ok, content} -> String.trim(content)
        {:error, _} -> nil
      end

    results =
      Enum.map(1..cfg.n_workers, fn i ->
        port = cfg.base_port + i - 1
        spawn_container(cfg, port, pubkey_content)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {ids, hosts} =
        results
        |> Enum.map(fn {:ok, id, host} -> {id, host} end)
        |> Enum.unzip()

      {:ok, ids, hosts}
    else
      # Clean up any containers that did start
      results
      |> Enum.filter(&match?({:ok, _, _}, &1))
      |> Enum.each(fn {:ok, id, _} ->
        System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)
      end)

      {:error, Enum.map_join(errors, "; ", fn {:error, r} -> r end)}
    end
  end

  defp spawn_container(%DockerConfig{} = cfg, port, pubkey_content) do
    name = "symphony-worker-#{port}"

    # Remove any stale container with the same name (e.g. from a previous crashed run)
    System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)

    mount_args = Enum.flat_map(cfg.mounts, fn m ->
      ["-v", "#{m.host}:#{m.container}:#{m.mode}"]
    end)

    pubkey_args =
      if pubkey_content do
        ["-e", "SYMPHONY_SSH_AUTHORIZED_KEY=#{pubkey_content}"]
      else
        []
      end

    args =
      ["run", "-d", "--restart", "always",
       "--name", "symphony-worker-#{port}",
       "--label", "symphony.managed=true",
       "-p", "#{port}:22"] ++
        mount_args ++
        pubkey_args ++
        [cfg.image]

    Logger.debug("DockerWorkerPool: docker #{Enum.join(args, " ")}")

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} ->
        id = String.trim(output)
        Logger.info("DockerWorkerPool: started container #{id} on port #{port}")
        {:ok, id, "localhost:#{port}"}

      {output, code} ->
        {:error, "docker run failed (exit #{code}): #{String.trim(output)}"}
    end
  end
end
