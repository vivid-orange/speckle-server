#!/bin/bash

# Bulk invite users to all Speckle projects
# Usage: ./bulk-invite.sh

# Configuration
SPECKLE_URL="${SPECKLE_URL:-https://speckle.magmaworks.co.uk}"
SPECKLE_TOKEN="${SPECKLE_TOKEN:-}"  # Set via environment or edit here
ROLE="${ROLE:-stream:contributor}"  # Options: stream:owner, stream:contributor, stream:reviewer

# Emails to invite (one per line)
EMAILS=(
  "user1@example.com"
  "user2@example.com"
  # Add more emails here
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check token
if [ -z "$SPECKLE_TOKEN" ]; then
  echo -e "${RED}Error: SPECKLE_TOKEN not set${NC}"
  echo "Generate a token at: $SPECKLE_URL/profile/access-tokens"
  echo "Required scopes: streams:read, streams:write, profile:read, users:invite"
  echo ""
  echo "Usage: SPECKLE_TOKEN=your-token ./bulk-invite.sh"
  exit 1
fi

# GraphQL endpoint
GQL_URL="$SPECKLE_URL/graphql"

# Function to make GraphQL requests
gql_request() {
  local query="$1"
  curl -s -X POST "$GQL_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $SPECKLE_TOKEN" \
    -d "$query"
}

# Get all projects
echo -e "${YELLOW}Fetching projects...${NC}"
PROJECTS_QUERY='{"query":"query { activeUser { projects(limit: 100) { items { id name } } } }"}'
PROJECTS_RESPONSE=$(gql_request "$PROJECTS_QUERY")

# Check for errors
if echo "$PROJECTS_RESPONSE" | grep -q '"errors"'; then
  echo -e "${RED}Error fetching projects:${NC}"
  echo "$PROJECTS_RESPONSE" | jq '.errors'
  exit 1
fi

# Extract project IDs and names
PROJECTS=$(echo "$PROJECTS_RESPONSE" | jq -r '.data.activeUser.projects.items[] | "\(.id)|\(.name)"')

if [ -z "$PROJECTS" ]; then
  echo -e "${RED}No projects found${NC}"
  exit 1
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo -e "${GREEN}Found $PROJECT_COUNT projects${NC}"
echo ""

# Build invite input array
build_invite_input() {
  local input="["
  local first=true
  for email in "${EMAILS[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      input+=","
    fi
    input+="{\"email\":\"$email\",\"role\":\"$ROLE\"}"
  done
  input+="]"
  echo "$input"
}

INVITE_INPUT=$(build_invite_input)
echo -e "${YELLOW}Inviting ${#EMAILS[@]} users to each project with role: $ROLE${NC}"
echo ""

# Invite users to each project
SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS='|' read -r project_id project_name; do
  echo -n "Inviting to: $project_name... "

  # Escape for JSON
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
    echo -e "${RED}FAILED${NC}"
    echo "$RESPONSE" | jq -r '.errors[0].message' 2>/dev/null || echo "$RESPONSE"
    ((FAIL_COUNT++))
  else
    echo -e "${GREEN}OK${NC}"
    ((SUCCESS_COUNT++))
  fi

  # Small delay to avoid rate limiting
  sleep 0.5
done <<< "$PROJECTS"

echo ""
echo -e "${GREEN}Completed: $SUCCESS_COUNT successful, $FAIL_COUNT failed${NC}"
