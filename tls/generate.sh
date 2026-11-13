#!/usr/bin/env bash
# Author: mskacelik
#
# Self-signed CA and one server certificate shared by both backend instances, so
# the gateways need a single trust anchor.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAYS=3650
NAMESPACE="${NAMESPACE:-skacelik-ns}"

SAN="DNS:localhost,IP:127.0.0.1"
for host in backend-a backend-b; do
  SAN="$SAN,DNS:$host,DNS:$host.$NAMESPACE.svc.cluster.local"
done

openssl req -newkey rsa:4096 -nodes \
  -keyout "$DIR/ca-key.pem" \
  -x509 -days "$DAYS" \
  -out "$DIR/ca-cert.pem" \
  -subj "/CN=edgy-k8s-benchmark-ca"

openssl req -newkey rsa:4096 -nodes \
  -keyout "$DIR/server-key.pem" \
  -out "$DIR/server.csr" \
  -subj "/CN=backend"

openssl x509 -req \
  -in "$DIR/server.csr" \
  -CA "$DIR/ca-cert.pem" \
  -CAkey "$DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$DIR/server-cert.pem" \
  -days "$DAYS" \
  -extfile <(printf "subjectAltName=%s" "$SAN")

chmod 644 "$DIR/server-key.pem" "$DIR/ca-key.pem"

rm -f "$DIR/server.csr" "$DIR/ca-cert.srl"
