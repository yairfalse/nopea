#!/usr/bin/env elixir

# NOPEA CI Pipeline
# Run with: sykli run
# Visualize with: sykli graph

Mix.install([
  {:sykli_sdk, github: "yairfalse/sykli", sparse: "sdk/elixir"}
])

Code.eval_string("""
use Sykli
alias Sykli.Condition

# Input patterns (using variables instead of module attributes for Code.eval_string context)
elixir_inputs = ["lib/**/*.ex", "test/**/*.exs", "config/**/*.exs", "mix.exs", "mix.lock"]
rust_inputs = ["nopea-git/src/**/*.rs", "nopea-git/Cargo.toml", "nopea-git/Cargo.lock"]
helm_inputs = ["charts/**/*.yaml", "charts/**/*.tpl"]
docker_inputs = ["Dockerfile", "mix.exs", "mix.lock", "lib/**/*.ex", "config/**/*.exs", "nopea-git/**/*"]

pipeline do
  # ============================================================================
  # ELIXIR BUILD & TEST
  # ============================================================================

  task "deps" do
    container "elixir:1.16-alpine"
    workdir "/app"
    run "mix deps.get"
    inputs ["mix.exs", "mix.lock"]
    outputs ["/app/deps"]
  end

  task "compile" do
    container "elixir:1.16-alpine"
    workdir "/app"
    run "mix compile --warnings-as-errors"
    after_ ["deps"]
    inputs elixir_inputs
  end

  task "test" do
    container "elixir:1.16-alpine"
    workdir "/app"
    run "mix test"
    after_ ["compile"]
    inputs elixir_inputs
  end

  task "format" do
    container "elixir:1.16-alpine"
    workdir "/app"
    run "mix format --check-formatted"
    inputs elixir_inputs
  end

  # ============================================================================
  # RUST BUILD (nopea-git binary)
  # ============================================================================

  task "rust-build" do
    container "rust:1.83-alpine"
    workdir "/app/nopea-git"
    run "apk add --no-cache musl-dev openssl-dev && cargo build --release"
    inputs rust_inputs
    output "binary", "/app/nopea-git/target/release/nopea-git"
  end

  task "rust-test" do
    container "rust:1.83-alpine"
    workdir "/app/nopea-git"
    run "apk add --no-cache musl-dev openssl-dev && cargo test"
    inputs rust_inputs
  end

  # ============================================================================
  # DOCKER BUILD
  # ============================================================================

  task "docker-build" do
    run "docker build -t nopea:ci ."
    after_ ["test", "rust-build"]
    inputs docker_inputs
  end

  # ============================================================================
  # HELM
  # ============================================================================

  task "helm-lint" do
    container "alpine/helm:3.16.0"
    workdir "/app"
    run "helm lint charts/nopea"
    inputs helm_inputs
  end

  task "helm-template" do
    container "alpine/helm:3.16.0"
    workdir "/app"
    run "helm template nopea charts/nopea --debug > /dev/null"
    after_ ["helm-lint"]
    inputs helm_inputs
  end

  # ============================================================================
  # RELEASE (only on main branch or tags)
  # ============================================================================

  task "docker-push" do
    run "docker push nopea:ci"
    after_ ["docker-build", "helm-template"]
    when_cond Condition.branch("main") |> Condition.or_cond(Condition.has_tag())
  end
end
""")
