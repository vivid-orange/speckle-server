#!/bin/bash

# Bulk add all users as collaborators to all projects via direct database insert
# This bypasses the invite system - users get immediate access
# Usage: ./bulk-add-collaborators-db.sh

# Configuration
ROLE="${ROLE:-stream:contributor}"  # Options: stream:owner, stream:contributor, stream:reviewer
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-speckle-server-postgres-1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}Bulk Add Collaborators (Direct Database)${NC}"
echo ""

# Check if postgres container is running
if ! docker ps --format '{{.Names}}' | grep -q "$POSTGRES_CONTAINER"; then
  echo -e "${RED}Error: PostgreSQL container '$POSTGRES_CONTAINER' not found${NC}"
  echo "Available containers:"
  docker ps --format '{{.Names}}' | grep -i postgres
  exit 1
fi

# Function to run SQL (stdin redirected to prevent consuming loop input)
run_sql() {
  docker exec -i "$POSTGRES_CONTAINER" psql -U speckle -d speckle -t -A -c "$1" < /dev/null
}

# Get all users (excluding the first admin user by creation date)
echo -e "${YELLOW}Fetching users...${NC}"
USERS=$(run_sql "SELECT id, name, email FROM users ORDER BY \"createdAt\" ASC;")

if [ -z "$USERS" ]; then
  echo -e "${RED}No users found${NC}"
  exit 1
fi

USER_COUNT=$(echo "$USERS" | wc -l)
echo -e "${GREEN}Found $USER_COUNT users${NC}"

# Get first user (admin) to exclude
ADMIN_ID=$(echo "$USERS" | head -1 | cut -d'|' -f1)
echo -e "Admin user ID: $ADMIN_ID (will be skipped)"
echo ""

# Show other users
echo -e "${CYAN}Users to add as collaborators:${NC}"
echo "$USERS" | tail -n +2 | while IFS='|' read -r id name email; do
  echo "  - $name ($email)"
done
echo ""

# Get all projects/streams
echo -e "${YELLOW}Fetching projects...${NC}"
PROJECTS=$(run_sql "SELECT id, name FROM streams ORDER BY \"createdAt\" ASC;")

if [ -z "$PROJECTS" ]; then
  echo -e "${RED}No projects found${NC}"
  exit 1
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo -e "${GREEN}Found $PROJECT_COUNT projects${NC}"
echo ""

# Confirm
USERS_TO_ADD=$((USER_COUNT - 1))
echo -e "${YELLOW}This will add $USERS_TO_ADD users to $PROJECT_COUNT projects with role: $ROLE${NC}"
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# Store users in array (excluding first/admin user)
USERS_TO_PROCESS=$(echo "$USERS" | tail -n +2)

# Add collaborators
while IFS='|' read -r project_id project_name; do
  echo -e "${CYAN}Project: $project_name${NC}"

  # Use process substitution to avoid subshell issues
  while IFS='|' read -r user_id user_name user_email; do
    # Check if already a collaborator
    EXISTS=$(run_sql "SELECT 1 FROM stream_acl WHERE \"userId\" = '$user_id' AND \"resourceId\" = '$project_id';")

    if [ -n "$EXISTS" ]; then
      echo -e "  $user_name: ${YELLOW}already collaborator${NC}"
    else
      # Insert collaborator
      run_sql "INSERT INTO stream_acl (\"userId\", \"resourceId\", role) VALUES ('$user_id', '$project_id', '$ROLE');" > /dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo -e "  $user_name: ${GREEN}added${NC}"
      else
        echo -e "  $user_name: ${RED}failed${NC}"
      fi
    fi
  done <<< "$USERS_TO_PROCESS"

  echo ""
done <<< "$PROJECTS"

echo -e "${GREEN}Done! Users now have immediate access.${NC}"
