FROM elixir:1.19.1-otp-28 AS build

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY WORKFLOW.md ./WORKFLOW.md

RUN mix escript.build

FROM elixir:1.19.1-otp-28 AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    SYMPHONY_APP_ROOT=/opt/symphony \
    SYMPHONY_LOGS_ROOT=/var/log/symphony \
    SYMPHONY_WORKSPACES_ROOT=/var/lib/symphony/workspaces \
    SYMPHONY_WORKFLOW_FILE=/opt/symphony/WORKFLOW.md \
    SYMPHONY_PORT=4000

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      nodejs \
      npm \
      tini && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex

WORKDIR /opt/symphony

COPY --from=build /app/bin/symphony /usr/local/bin/symphony
COPY --from=build /app/WORKFLOW.md /opt/symphony/WORKFLOW.md
COPY docker/entrypoint.sh /usr/local/bin/symphony-entrypoint

RUN sed -i 's/\r$//' /usr/local/bin/symphony-entrypoint && \
    chmod +x /usr/local/bin/symphony /usr/local/bin/symphony-entrypoint && \
    mkdir -p /var/log/symphony /var/lib/symphony/workspaces /root/.codex

VOLUME ["/var/log/symphony", "/var/lib/symphony/workspaces", "/root/.codex"]

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-entrypoint"]
CMD []
