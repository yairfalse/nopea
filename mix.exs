defmodule Nopea.MixProject do
  use Mix.Project

  def project do
    [
      app: :nopea,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      description: "Fast GitOps controller for Kubernetes",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Nopea.Application, []}
    ]
  end

  defp deps do
    [
      # K8s client
      {:k8s, "~> 2.6"},

      # YAML parsing
      {:yaml_elixir, "~> 2.9"},

      # HTTP client (for webhooks, CDEvents)
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Msgpack (for Rust Port protocol)
      {:msgpax, "~> 2.4"},

      # Web server (for webhooks)
      {:plug_cowboy, "~> 2.7"},

      # Telemetry & Metrics
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp package do
    [
      name: "nopea",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/yairfalse/nopea"}
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      flags: [:error_handling, :underspecs]
    ]
  end
end
