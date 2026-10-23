#!/usr/bin/env bash
# Compiles 20260925090000_admin_analytics.sql against a throwaway Postgres and
# checks the reports on seeded data, including that a non-developer is refused.
# Usage: bash supabase/tests/analytics/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
migration="$here/../../migrations/20260925090000_admin_analytics.sql"
container="x5-analytics-test-$$"

docker run -d --name "$container" -e POSTGRES_PASSWORD=test postgres:15 >/dev/null
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done

docker exec "$container" psql -U postgres -q -c 'create role anon; create role authenticated; create role service_role;'
for file in "$here/stubs.sql" "$migration" "$here/smoke.sql"; do
  docker cp "$file" "$container:/tmp/step.sql" >/dev/null
  MSYS_NO_PATHCONV=1 docker exec "$container" psql -U postgres -v ON_ERROR_STOP=1 -q -f /tmp/step.sql
done
echo "analytics migration OK"
