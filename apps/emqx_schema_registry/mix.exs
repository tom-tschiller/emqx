defmodule EMQXSchemaRegistry.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_schema_registry,
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
    [extra_applications: [], mod: {:emqx_schema_registry_app, []}]
  end

  def deps() do
    [
      {:emqx, in_umbrella: true},
      {:emqx_utils, in_umbrella: true},
      {:emqx_rule_engine, in_umbrella: true},
      {:erlavro, github: "emqx/erlavro", tag: "2.10.0"},
      {:jesse, github: "emqx/jesse", tag: "1.8.0"},
      {:gpb, "4.19.9"}
    ]
  end
end
