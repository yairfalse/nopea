import Config

# Runtime configuration (read at runtime, not compile time)
if config_env() == :prod do
  # Parse integer env var with default, logs warning on invalid value
  parse_integer = fn env_var, default ->
    case System.get_env(env_var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} ->
            int

          _ ->
            IO.warn("Invalid integer for #{env_var}: #{inspect(value)}, using default #{default}")
            default
        end
    end
  end

  config :nopea,
    enable_controller: System.get_env("NOPEA_ENABLE_CONTROLLER", "true") == "true",
    watch_namespace: System.get_env("WATCH_NAMESPACE", ""),
    # Leader election for HA deployments
    enable_leader_election: System.get_env("NOPEA_ENABLE_LEADER_ELECTION", "false") == "true",
    leader_lease_name: System.get_env("NOPEA_LEADER_LEASE_NAME", "nopea-leader-election"),
    leader_lease_duration: parse_integer.("NOPEA_LEADER_LEASE_DURATION", 15),
    leader_renew_deadline: parse_integer.("NOPEA_LEADER_RENEW_DEADLINE", 10),
    leader_retry_period: parse_integer.("NOPEA_LEADER_RETRY_PERIOD", 2)
end
