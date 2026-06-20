# Links

## Setup

Requires PostgreSQL. Configure via `DATABASE_URL` or the defaults in `config/dev.exs` (`links_dev` on localhost).

* Run `mix setup` to install dependencies, create the database, and run migrations
* Start the server with `mix phx.server` or `iex -S mix phx.server`

Visit [`localhost:4000`](http://localhost:4000) from your browser.

Production requires the `DATABASE_URL` environment variable (for example `ecto://USER:PASS@HOST/DATABASE`).

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
