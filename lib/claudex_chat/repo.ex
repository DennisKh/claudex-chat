defmodule ClaudexChat.Repo do
  use Ecto.Repo,
    otp_app: :claudex_chat,
    adapter: Ecto.Adapters.Postgres
end
