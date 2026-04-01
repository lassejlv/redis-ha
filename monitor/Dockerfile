FROM rust:1.82-alpine AS builder
RUN apk add --no-cache musl-dev pkgconfig openssl-dev openssl-libs-static
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release 2>/dev/null || true && rm -rf src
COPY src/ src/
RUN cargo build --release

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/target/release/redis-ha-monitor /usr/local/bin/
ENTRYPOINT ["redis-ha-monitor"]
