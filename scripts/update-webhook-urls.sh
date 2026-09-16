#!/usr/bin/env bash
set -euo pipefail

# Rewrites webhook URLs after the Azure app rename.
# Dry-run by default; pass --apply to commit the changes.
#
#   assets-api.azurewebsites.net     -> magmaworks-services-assets.azurewebsites.net
#   assets-api-uat.azurewebsites.net -> uat-magmaworks-services-assets.azurewebsites.net
#
# The /speckle-webhook path is preserved.

cd "$(dirname "$0")/.."

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

PSQL=(docker compose -f docker-compose-deps.yml exec -T postgres psql -U speckle -d speckle -v ON_ERROR_STOP=1)

echo "== Current URL distribution =="
"${PSQL[@]}" -c 'SELECT url, COUNT(*) FROM webhooks_config GROUP BY url ORDER BY COUNT(*) DESC;'

echo
echo "== Preview of changes =="
"${PSQL[@]}" <<'SQL'
SELECT
  url AS old_url,
  REPLACE(
    REPLACE(url,
      'assets-api-uat.azurewebsites.net',
      'uat-magmaworks-services-assets.azurewebsites.net'),
    'assets-api.azurewebsites.net',
    'magmaworks-services-assets.azurewebsites.net'
  ) AS new_url,
  COUNT(*) AS affected
FROM webhooks_config
WHERE url LIKE '%assets-api%azurewebsites.net%'
GROUP BY url
ORDER BY url;
SQL

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "Dry run only. Re-run with --apply to perform the update."
  exit 0
fi

echo
echo "== Applying update =="
"${PSQL[@]}" <<'SQL'
BEGIN;

-- Order matters: replace the more-specific UAT host first so the prod rule
-- does not swallow it.
UPDATE webhooks_config
SET url = REPLACE(url,
      'assets-api-uat.azurewebsites.net',
      'uat-magmaworks-services-assets.azurewebsites.net'),
    "updatedAt" = NOW()
WHERE url LIKE '%assets-api-uat.azurewebsites.net%';

UPDATE webhooks_config
SET url = REPLACE(url,
      'assets-api.azurewebsites.net',
      'magmaworks-services-assets.azurewebsites.net'),
    "updatedAt" = NOW()
WHERE url LIKE '%assets-api.azurewebsites.net%';

COMMIT;
SQL

echo
echo "== New URL distribution =="
"${PSQL[@]}" -c 'SELECT url, COUNT(*) FROM webhooks_config GROUP BY url ORDER BY COUNT(*) DESC;'
