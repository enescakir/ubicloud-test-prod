FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends netcat ca-certificates && rm -rf /var/lib/apt/lists/*
