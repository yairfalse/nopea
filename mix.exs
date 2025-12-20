defmodule Nopea.MixProject do
  use Mix.Project

  def project do
    [
      app: :nopea,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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

      # Telemetry
      {:telemetry, "~> 1.2"},

      # Dev/Test
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
end
