#!/bin/bash

# Let's Encrypt initialization script for Speckle
# This script obtains SSL certificates from Let's Encrypt using standalone mode

set -e

DOMAIN="speckle.whitbywood.com"
DOMAIN_ALIAS="speckle.magmaworks.co.uk"
EMAIL="t.reinhardt@whitbywood.com"
COMPOSE_FILE="docker-compose-speckle.yml"
RSA_KEY_SIZE=4096

# Check if running from the correct directory
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Error: $COMPOSE_FILE not found. Please run this script from the speckle-server root directory."
  exit 1
fi

echo "### Step 1: Stopping nginx if running (need port 80 for certbot)..."
docker compose -f "$COMPOSE_FILE" stop speckle-ingress 2>/dev/null || true

echo "### Step 2: Cleaning up any stale certbot containers..."
docker stop $(docker ps -q --filter "ancestor=certbot/certbot:latest") 2>/dev/null || true
docker rm $(docker ps -aq --filter "ancestor=certbot/certbot:latest") 2>/dev/null || true

echo "### Step 3: Requesting Let's Encrypt certificate for $DOMAIN..."
# Use standalone mode - certbot runs its own temporary web server
docker run --rm -p 80:80 \
  -v speckle-server_certbot-certs:/etc/letsencrypt \
  -v speckle-server_certbot-webroot:/var/www/certbot \
  certbot/certbot certonly --standalone \
    --email "$EMAIL" \
    --domain "$DOMAIN" \
    --rsa-key-size "$RSA_KEY_SIZE" \
    --agree-tos \
    --non-interactive

if [ -n "$DOMAIN_ALIAS" ]; then
  echo "### Step 3b: Requesting Let's Encrypt certificate for alias $DOMAIN_ALIAS..."
  docker run --rm -p 80:80 \
    -v speckle-server_certbot-certs:/etc/letsencrypt \
    -v speckle-server_certbot-webroot:/var/www/certbot \
    certbot/certbot certonly --standalone \
      --email "$EMAIL" \
      --domain "$DOMAIN_ALIAS" \
      --rsa-key-size "$RSA_KEY_SIZE" \
      --agree-tos \
      --non-interactive
fi

echo "### Step 4: Building and starting all services..."
docker compose -f "$COMPOSE_FILE" build
docker compose -f "$COMPOSE_FILE" up -d

echo "### Step 5: Waiting for services to start..."
sleep 10

echo "### Done! SSL certificate obtained successfully."
echo ""
echo "Verifying HTTPS is working..."
curl -sI "https://$DOMAIN" 2>/dev/null | head -5 || echo "Could not verify HTTPS (may need DNS propagation)"
echo ""
echo "Services are running. To check status:"
echo "  docker compose -f $COMPOSE_FILE ps"
echo ""
echo "To check certificate status:"
echo "  docker compose -f $COMPOSE_FILE run --rm certbot certificates"
echo ""
echo "Certificate will auto-renew via the certbot container."
