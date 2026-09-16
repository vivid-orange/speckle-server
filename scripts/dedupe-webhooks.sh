#!/usr/bin/env bash
set -euo pipefail

# Removes duplicate webhooks_config rows, keeping the oldest (by createdAt) per
# (streamId, url). Dry-run by default; pass --apply to actually delete.
#
# WARNING: webhooks_events has ON DELETE CASCADE against webhooks_config, so
# dropping a duplicate also drops its delivery history. The row kept for each
# (streamId, url) pair retains its own history.

cd "$(dirname "$0")/.."

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
fi

PSQL=(docker compose -f docker-compose-deps.yml exec -T postgres psql -U speckle -d speckle -v ON_ERROR_STOP=1)

echo "== Duplicates to be removed =="
"${PSQL[@]}" <<'SQL'
WITH ranked AS (
  SELECT id, "streamId", url, "createdAt",
         ROW_NUMBER() OVER (
           PARTITION BY "streamId", url
           ORDER BY "createdAt" ASC, id ASC
         ) AS rn
  FROM webhooks_config
)
SELECT id, "streamId", url, "createdAt"
FROM ranked
WHERE rn > 1
ORDER BY "streamId", "createdAt";
SQL

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "Dry run only. Re-run with --apply to delete the rows above."
  exit 0
fi

echo
echo "== Applying deletion =="
"${PSQL[@]}" <<'SQL'
BEGIN;
WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY "streamId", url
           ORDER BY "createdAt" ASC, id ASC
         ) AS rn
  FROM webhooks_config
)
DELETE FROM webhooks_config
WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
RETURNING id, "streamId", url;
COMMIT;
SQL

echo
echo "== Remaining hooks per (streamId, url) =="
"${PSQL[@]}" -c 'SELECT "streamId", url, COUNT(*) FROM webhooks_config GROUP BY "streamId", url HAVING COUNT(*) > 1;'
echo "(empty result = no duplicates left)"
