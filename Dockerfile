FROM elixir:1.20
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -V -y --no-install-recommends \
                    build-essential npm git postgresql-client && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix compile
RUN npm install --prefix assets
RUN MIX_ENV=prod mix assets.deploy
RUN MIX_ENV=prod mix phx.digest
RUN MIX_ENV=prod mix release

CMD ["_build/prod/rel/links/bin/links", "start"]
