FROM elixir:1.19 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
COPY elixir/config ./config
RUN mix deps.get --only prod

COPY elixir/. .
RUN mix deps.compile && mix escript.build

FROM elixir:1.19

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /var/lib/symphony -s /bin/bash symphony \
  && install -d -m 755 -o symphony -g symphony /etc/symphony/workflow \
  && install -d -m 775 -o symphony -g symphony /var/lib/symphony/workspaces

COPY --from=builder /build/bin/symphony /usr/local/bin/symphony

USER symphony
WORKDIR /var/lib/symphony
ENV HOME=/var/lib/symphony

EXPOSE 4000

ENTRYPOINT ["symphony"]
