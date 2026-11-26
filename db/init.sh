#!/bin/sh
# One-shot database initializer for the web chat project.
# Applies the idempotent schema and seeds a demo tenant only on an empty install.
set -eu

: "${DATABASE_URL:?DATABASE_URL is not set}"

echo "[db-init] applying schema"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f /db/schema.sql
echo "[db-init] schema ok"

count="$(psql "$DATABASE_URL" -tAc 'select count(*) from tenants')"
if [ "$count" = "0" ]; then
  echo "[db-init] no tenants yet -> seeding demo tenant"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f /db/seed_tenant_web.sql
  echo "[db-init] seed ok"
else
  echo "[db-init] tenants exist ($count) -> seed skipped"
fi

echo "[db-init] done"
