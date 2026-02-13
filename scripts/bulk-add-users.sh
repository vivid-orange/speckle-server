#!/bin/bash

# Bulk add all registered users to all projects
# This directly adds users as collaborators (no invite acceptance needed)
# Usage: SPECKLE_TOKEN=your-token ./bulk-add-users.sh

# Configuration
SPECKLE_URL="${SPECKLE_URL:-https://speckle.magmaworks.co.uk}"
SPECKLE_TOKEN="${SPECKLE_TOKEN:-}"
ROLE="${ROLE:-stream:contributor}"  # Options: stream:owner, stream:contributor, stream:reviewer

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$SPECKLE_TOKEN" ]; then
  echo -e "${RED}Error: SPECKLE_TOKEN not set${NC}"
  echo "Generate a token at: $SPECKLE_URL/profile/access-tokens"
  echo "Required scopes: streams:read, streams:write, users:read"
  echo ""
  echo "Usage: SPECKLE_TOKEN=your-token ./bulk-add-users.sh"
  exit 1
fi

GQL_URL="$SPECKLE_URL/graphql"

gql_request() {
  curl -s -X POST "$GQL_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SPECKLE_TOKEN" \
    -d "$1"
}

# Get current user ID (to exclude from adding)
echo -e "${YELLOW}Getting current user...${NC}"
ME_RESPONSE=$(gql_request '{"query":"{ activeUser { id } }"}')
MY_USER_ID=$(echo "$ME_RESPONSE" | jq -r '.data.activeUser.id')
echo -e "Current user ID: $MY_USER_ID"
echo ""

# Get all users from the server (requires admin)
echo -e "${YELLOW}Fetching all registered users...${NC}"
USERS_QUERY='{"query":"query { admin { userList(limit: 500) { items { id name email } } } }"}'
USERS_RESPONSE=$(gql_request "$USERS_QUERY")

if echo "$USERS_RESPONSE" | grep -q '"errors"'; then
  echo -e "${RED}Error fetching users (requires server:admin role):${NC}"
  echo "$USERS_RESPONSE" | jq '.errors[0].message' 2>/dev/null
  exit 1
fi

# Extract users (excluding current user)
USERS=$(echo "$USERS_RESPONSE" | jq -r --arg myid "$MY_USER_ID" '.data.admin.userList.items[] | select(.id != $myid) | "\(.id)|\(.name)|\(.email)"')

if [ -z "$USERS" ]; then
  echo -e "${RED}No other users found${NC}"
  exit 1
fi

USER_COUNT=$(echo "$USERS" | wc -l)
echo -e "${GREEN}Found $USER_COUNT users (excluding yourself)${NC}"
echo ""

# Show users
echo -e "${CYAN}Users to add:${NC}"
echo "$USERS" | while IFS='|' read -r id name email; do
  echo "  - $name ($email)"
done
echo ""

# Get all projects
echo -e "${YELLOW}Fetching projects...${NC}"
PROJECTS_RESPONSE=$(gql_request '{"query":"{ activeUser { projects(limit: 100) { items { id name } } } }"}')

if echo "$PROJECTS_RESPONSE" | grep -q '"errors"'; then
  echo -e "${RED}Error fetching projects:${NC}"
  echo "$PROJECTS_RESPONSE" | jq '.errors'
  exit 1
fi

PROJECTS=$(echo "$PROJECTS_RESPONSE" | jq -r '.data.activeUser.projects.items[] | "\(.id)|\(.name)"')

if [ -z "$PROJECTS" ]; then
  echo -e "${RED}No projects found${NC}"
  exit 1
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo -e "${GREEN}Found $PROJECT_COUNT projects${NC}"
echo ""

# Confirm
echo -e "${YELLOW}This will add $USER_COUNT users to $PROJECT_COUNT projects with role: $ROLE${NC}"
read -p "Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# Add each user to each project
TOTAL_SUCCESS=0
TOTAL_FAIL=0

while IFS='|' read -r project_id project_name; do
  echo -e "${CYAN}Project: $project_name${NC}"

  # Build invite input with userIds
  INVITE_INPUT="["
  FIRST=true
  while IFS='|' read -r user_id user_name user_email; do
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      INVITE_INPUT+=","
    fi
    INVITE_INPUT+="{\"userId\":\"$user_id\",\"role\":\"$ROLE\"}"
  done <<< "$USERS"
  INVITE_INPUT+="]"

  echo -n "  Inviting all users... "

  MUTATION=$(cat <<EOF
{
  "query": "mutation BatchInvite(\$projectId: ID!, \$input: [ProjectInviteCreateInput!]!) { projectMutations { invites { batchCreate(projectId: \$projectId, input: \$input) { id } } } }",
  "variables": {
    "projectId": "$project_id",
    "input": $INVITE_INPUT
  }
}
EOF
)

  RESPONSE=$(gql_request "$MUTATION")

  if echo "$RESPONSE" | grep -q '"errors"'; then
    ERROR=$(echo "$RESPONSE" | jq -r '.errors[0].message' 2>/dev/null)
    echo -e "${RED}FAILED${NC} - $ERROR"
    ((TOTAL_FAIL++))
  else
    echo -e "${GREEN}OK${NC}"
    ((TOTAL_SUCCESS++))
  fi

  sleep 0.3

  echo ""
done <<< "$PROJECTS"

echo -e "${GREEN}Completed: $TOTAL_SUCCESS added, $TOTAL_FAIL failed${NC}"
