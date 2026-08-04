#!/usr/bin/env bash
set -euo pipefail
OUT="./traefik/dynamic.yml"
TMP="$(mktemp)"
echo "Fetching Cloudflare IP lists..."
v4=$(curl -fsS https://www.cloudflare.com/ips-v4)
v6=$(curl -fsS https://www.cloudflare.com/ips-v6)

cat > "$TMP" <<'YAML'
http:
  middlewares:
    ipWhitelistCloudflare:
      ipWhiteList:
        sourceRange:
          - "127.0.0.1/32"
          - "172.16.0.0/12"
YAML

# Append IPv4 ranges
while read -r cidr; do
  echo "          - \"$cidr\"" >> "$TMP"
done <<< "$v4"

# Append IPv6 ranges
while read -r cidr; do
  echo "          - \"$cidr\"" >> "$TMP"
done <<< "$v6"

cat >> "$TMP" <<'YAML'

    ratelimit_global:
      rateLimit:
        average: 5
        burst: 10
    ratelimit_api:
      rateLimit:
        average: 1
        burst: 4
    security_headers:
      headers:
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        sslRedirect: true
        forceSTSHeader: true
    prevent_scrape:
      chain:
        middlewares:
          - ipWhitelistCloudflare
          - ratelimit_global
          - security_headers
    api_ratelimit:
      chain:
        middlewares:
          - ipWhitelistCloudflare
          - ratelimit_api
          - security_headers
YAML

mv "$TMP" "$OUT"
echo "Updated $OUT with latest Cloudflare IPs."