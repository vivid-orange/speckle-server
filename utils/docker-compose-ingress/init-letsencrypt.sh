#!/bin/bash

# Let's Encrypt initialization script for Speckle
#
# Initial acquisition uses standalone mode (port 80) because nginx cannot start
# without an existing cert (its config references /etc/letsencrypt/live/...).
# Once services are up, we re-issue via webroot mode so the renewal config in
# /etc/letsencrypt/renewal/<domain>.conf is set to authenticator = webroot.
# This is what makes the certbot container's nightly `certbot renew` loop work:
# nginx (which holds port 80) serves the ACME challenge from /var/www/certbot,
# instead of certbot trying to bind port 80 itself and getting a 404 from nginx.

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

echo "### Step 6: Switching renewal config from standalone to webroot..."
# Re-issue each cert via webroot so /etc/letsencrypt/renewal/<domain>.conf is
# saved with authenticator = webroot. Without this, the certbot container's
# nightly `certbot renew` would inherit standalone mode and fail to bind
# port 80 (nginx already has it), so renewals would silently fail until the
# cert expires. --force-renewal ensures the issuance actually runs even
# though the cert from step 3 isn't due for renewal yet.
docker compose -f "$COMPOSE_FILE" exec -T certbot certbot certonly --webroot \
  --webroot-path /var/www/certbot \
  --email "$EMAIL" \
  --domain "$DOMAIN" \
  --rsa-key-size "$RSA_KEY_SIZE" \
  --agree-tos \
  --non-interactive \
  --force-renewal

if [ -n "$DOMAIN_ALIAS" ]; then
  docker compose -f "$COMPOSE_FILE" exec -T certbot certbot certonly --webroot \
    --webroot-path /var/www/certbot \
    --email "$EMAIL" \
    --domain "$DOMAIN_ALIAS" \
    --rsa-key-size "$RSA_KEY_SIZE" \
    --agree-tos \
    --non-interactive \
    --force-renewal
fi

echo "### Step 7: Reloading nginx to pick up the webroot-issued certificates..."
docker compose -f "$COMPOSE_FILE" exec speckle-ingress nginx -s reload

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
