defmodule EMQXSchemaValidation.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_schema_validation,
      version: "0.1.0",
      build_path: "../../_build",
      erlc_options: EMQXUmbrella.MixProject.erlc_options(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [], mod: {:emqx_schema_validation_app, []}]
  end

  def deps() do
    [
      {:emqx, in_umbrella: true},
      {:emqx_utils, in_umbrella: true},
      {:emqx_rule_engine, in_umbrella: true},
      {:emqx_schema_registry, in_umbrella: true}
    ]
  end
end
