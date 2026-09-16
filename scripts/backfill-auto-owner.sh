#!/bin/bash

# One-time backfill for AUTO_OWNER_EMAIL.
#
# The auto-collaborator listeners only fire on user/project creation, so enabling
# AUTO_OWNER_EMAIL does not touch projects that already exist. This grants the
# configured account stream:owner on every current project, in a single upsert.
#
# Usage: AUTO_OWNER_EMAIL=d.veld@whitbywood.com ./backfill-auto-owner.sh
#        (falls back to AUTO_OWNER_EMAIL from ../.env)

set -euo pipefail

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-speckle-server-postgres-1}"
ROLE="stream:owner"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Fall back to the deployment's .env so this matches what the server is running
ENV_FILE="$(dirname "$0")/../.env"
if [ -z "${AUTO_OWNER_EMAIL:-}" ] && [ -f "$ENV_FILE" ]; then
  AUTO_OWNER_EMAIL=$(grep -E '^AUTO_OWNER_EMAIL=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"'"'"' ' || true)
fi

if [ -z "${AUTO_OWNER_EMAIL:-}" ]; then
  echo -e "${RED}Error: AUTO_OWNER_EMAIL not set and not found in $ENV_FILE${NC}"
  echo "Usage: AUTO_OWNER_EMAIL=user@example.com $0"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "$POSTGRES_CONTAINER"; then
  echo -e "${RED}Error: PostgreSQL container '$POSTGRES_CONTAINER' not found${NC}"
  docker ps --format '{{.Names}}' | grep -i postgres || true
  exit 1
fi

run_sql() {
  docker exec -i "$POSTGRES_CONTAINER" psql -U speckle -d speckle -t -A -c "$1" < /dev/null
}

# Resolve the account first so a typo fails loudly instead of silently doing nothing
USER_ROW=$(run_sql "SELECT id, name FROM users WHERE LOWER(email) = LOWER('$AUTO_OWNER_EMAIL');")
if [ -z "$USER_ROW" ]; then
  echo -e "${RED}Error: no account found for '$AUTO_OWNER_EMAIL'${NC}"
  exit 1
fi

USER_ID="${USER_ROW%%|*}"
USER_NAME="${USER_ROW#*|}"

PROJECT_COUNT=$(run_sql "SELECT count(*) FROM streams;")
ALREADY_OWNER=$(run_sql "SELECT count(*) FROM stream_acl WHERE \"userId\" = '$USER_ID' AND role = '$ROLE';")
TO_CHANGE=$((PROJECT_COUNT - ALREADY_OWNER))

echo -e "${CYAN}Auto-owner backfill${NC}"
echo -e "  Account:       $USER_NAME <$AUTO_OWNER_EMAIL> ($USER_ID)"
echo -e "  Projects:      $PROJECT_COUNT"
echo -e "  Already owner: $ALREADY_OWNER"
echo -e "  ${YELLOW}Will grant $ROLE on $TO_CHANGE project(s)${NC}"
echo ""

if [ "$TO_CHANGE" -eq 0 ]; then
  echo -e "${GREEN}Nothing to do.${NC}"
  exit 0
fi

read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Single upsert: inserts where no ACL row exists, promotes the row where one does.
UPDATED=$(run_sql "
  INSERT INTO stream_acl (\"userId\", \"resourceId\", role)
  SELECT '$USER_ID', id, '$ROLE' FROM streams
  ON CONFLICT (\"userId\", \"resourceId\") DO UPDATE SET role = EXCLUDED.role
  RETURNING 1;" | grep -c '^1$' || true)

echo ""
echo -e "${GREEN}Done. $UPDATED ACL row(s) now grant $ROLE to $USER_NAME.${NC}"

FINAL=$(run_sql "SELECT count(*) FROM stream_acl WHERE \"userId\" = '$USER_ID' AND role = '$ROLE';")
echo -e "Verified: owner on $FINAL of $PROJECT_COUNT projects."
