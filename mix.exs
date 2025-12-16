defmodule Alumiini.MixProject do
  use Mix.Project

  def project do
    [
      app: :alumiini,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "GitOps controller for Kubernetes - part of the Finnish Stack",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Alumiini.Application, []}
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
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "alumiini",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/false-systems/alumiini"}
    ]
  end
end
