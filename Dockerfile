FROM node:22-slim

RUN apt update -qq && apt install -y --no-install-recommends openssl tini && apt clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*