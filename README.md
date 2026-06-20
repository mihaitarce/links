# Links

A self-hosted bookmark manager built with [Phoenix](https://www.phoenixframework.org/) and LiveView. Organize links in an inbox and nested collections, share them with collaborators, and publish read-only public pages.

## Features

- **Inbox and collections** — paste URLs into the inbox or add them directly to nested collections
- **Drag and drop** — reorder collections and move links between the inbox and collections
- **Collaboration** — invite other users with read-only or edit access
- **Public sharing** — create share links for read-only public views of a collection
- **Subscribe from a share URL** — paste a `/share/…` link into the inbox to add a read-only copy of a shared collection
- **Metadata** — titles and favicons are fetched in the background for new links

## Development

Requires PostgreSQL. By default, development uses the `links_dev` database on `localhost` (see `config/dev.exs`). Override with `DATABASE_URL` if needed.

```bash
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000).

`mix setup` installs dependencies, creates the database, runs migrations, and seeds demo data.

### Demo account

After seeding:

| Email | Password |
| --- | --- |
| `demouser@example.com` | `demouserpass12` |

Re-seed at any time with:

```bash
mix run priv/repo/seeds.exs
```

### Tests

```bash
mix test
mix precommit
```

## Production

Required environment variables:

| Variable | Description |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL, e.g. `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Session signing secret (`mix phx.gen.secret`) |
| `PHX_SERVER` | Set to `true` when running a release |

Optional:

| Variable | Description |
| --- | --- |
| `PHX_HOST` | Public hostname for URL generation (default: `example.com`) |
| `PORT` | HTTP port (default: `4000`) |
| `POOL_SIZE` | Database connection pool size (default: `10`) |
| `PHOENIX_BASE_URL` | Path prefix when served behind a reverse proxy, e.g. `/links` |
| `PHOENIX_FORWARD_AUTH` | Set to `true` to authenticate via the `X-Authenticated-User` header instead of local login |

Build and run a release:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
PHX_SERVER=true DATABASE_URL=... SECRET_KEY_BASE=... _build/prod/rel/links/bin/links start
```

### Docker

```bash
docker compose up --build
```

The app service reads configuration from `links.env`. Postgres is included in `docker-compose.yml`. At minimum, set `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_SERVER=true` in `links.env`.

### Reverse-proxy authentication

When `PHOENIX_FORWARD_AUTH=true`, Links trusts the `X-Authenticated-User` header from your reverse proxy and auto-provisions users. The header value is stored as the user identifier (in the email field) without requiring a valid email address. Local registration, login, logout, and settings are disabled.

See `Caddyfile` for an example Caddy setup with a `/links` base path and forward auth.

## License

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only)
