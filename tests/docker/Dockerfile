FROM rust:1.87-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    jq \
    procps \
    bash \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/agent-store /usr/local/bin/agent-store
COPY tests/docker/schedule_tests.sh /tests/schedule_tests.sh
RUN chmod +x /tests/schedule_tests.sh

WORKDIR /workspace
ENTRYPOINT ["/tests/schedule_tests.sh"]
