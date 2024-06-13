defmodule EMQXDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :emqx_dashboard,
      version: "0.1.0",
      build_path: "../../_build",
      # config_path: "../../config/config.exs",
      erlc_options: EMQXUmbrella.MixProject.erlc_options(),
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications
  def application do
    [
      extra_applications: [],
      mod: {:emqx_dashboard_app, []}
    ]
  end

  def deps() do
    [
      {:emqx, in_umbrella: true},
      {:minirest, github: "emqx/minirest", tag: "1.4.1"},
    ]
  end
end
