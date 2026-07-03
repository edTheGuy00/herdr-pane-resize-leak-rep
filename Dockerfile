# Reproduces the herdr direct-attach resize-lock leak in one `docker run`.
# herdr is downloaded as the UNMODIFIED official release binary (AGPL-3.0,
# separate process, driven only over its public sockets). x86_64 only.

FROM rust:1-slim AS build
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tmux procps curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Pin the herdr release under test (wire PROTOCOL_VERSION 14 = v0.7.1).
ARG HERDR_VERSION=0.7.1
RUN curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/ogulcancelik/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64" \
 && chmod +x /usr/local/bin/herdr \
 && head -c 64 /usr/local/bin/herdr | grep -q ELF

COPY --from=build /src/target/release/herdr-pane-resize-leak-rep /usr/local/bin/
COPY repro.sh /usr/local/bin/repro.sh
RUN chmod +x /usr/local/bin/repro.sh

ENV TERM=xterm-256color
ENTRYPOINT ["/usr/local/bin/repro.sh"]
