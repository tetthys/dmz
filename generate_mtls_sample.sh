#!/usr/bin/env bash
set -euo pipefail

OUTDIR="./certs"
mkdir -p "$OUTDIR"
cd "$OUTDIR"

# 1) Create CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=Example CA" -out ca.crt

# 2) Server cert (internal service)
openssl genrsa -out server.key 4096
openssl req -new -key server.key -subj "/CN=internal-service" -out server.csr
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256

# 3) Client cert (web)
openssl genrsa -out client.key 4096
openssl req -new -key client.key -subj "/CN=web-client" -out client.csr
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 365 -sha256

echo "Certificates generated in $PWD: ca.crt, server.crt, server.key, client.crt, client.key"
