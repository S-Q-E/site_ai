# One-shot Railway service: creates the app schema in the project's Postgres.
# Runs once per deploy and exits; restart policy must be NEVER.
FROM postgres:18-alpine

WORKDIR /db
COPY schema.sql /db/schema.sql
COPY seed_tenant_web.sql /db/seed_tenant_web.sql
COPY db/init.sh /db/init.sh
RUN chmod +x /db/init.sh

ENTRYPOINT ["/db/init.sh"]
