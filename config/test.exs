import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :claudex_chat, ClaudexChat.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "claudex_chat_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :claudex_chat, ClaudexChatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PDNHdRYF2hrZss5RiNlIbiCiA4Qs2inb0fr0WZ0qJHVSYW/BoVr1Cq+CSnsWPzDu",
  server: false

# In test we don't send emails
config :claudex_chat, ClaudexChat.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Serve the built-in model catalogue in tests: the suite makes no API calls.
config :claudex_chat, ClaudexChat.Models, refresh: false

# Tests that exercise the file tools set their own root; this keeps a stray
# relative path from reaching the real project directory.
config :claudex_chat, default_root: Path.join(System.tmp_dir!(), "claudex_chat_test_root")
