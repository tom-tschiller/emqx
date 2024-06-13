defmodule EMQXGatewayOcpp.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_gateway_ocpp,
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
    [extra_applications: []]
  end

  def deps() do
    [
      {:jesse, github: "emqx/jesse", tag: "1.8.0"},
      {:emqx, in_umbrella: true},
      {:emqx_utils, in_umbrella: true},
      {:emqx_gateway, in_umbrella: true}
    ]
  end
end
