# Speckle Backup Guide

## Prerequisites

Ensure the backup directory exists:

```bash
mkdir -p /home/speckle-user/backup
```

## Quick One-Time Backup (Before Updates)

This backs up all Docker volumes while services are stopped:

```bash
cd /home/speckle-user/git/speckle-server
docker compose -f docker-compose-speckle.yml down
docker compose -f docker-compose-deps.yml down

# Backup all volumes
docker run --rm \
  -v speckle-server_postgres-data:/source/postgres:ro \
  -v speckle-server_redis-data:/source/redis:ro \
  -v speckle-server_minio-data:/source/minio:ro \
  -v /home/speckle-user/backup:/backup \
  alpine tar czf /backup/speckle-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /source .

docker compose -f docker-compose-deps.yml up -d
docker compose -f docker-compose-speckle.yml up -d
```

## PostgreSQL-Only Backup (While Running)

This creates a database dump without stopping services:

```bash
docker exec speckle-server-postgres-1 pg_dump -U speckle speckle | gzip > /home/speckle-user/backup/speckle-db-$(date +%Y%m%d).sql.gz
```

## Restore from Full Volume Backup

Restore all volumes from a full backup:

```bash
cd /home/speckle-user/git/speckle-server
docker compose -f docker-compose-speckle.yml down
docker compose -f docker-compose-deps.yml down

# Restore all volumes (replace filename with your backup)
docker run --rm \
  -v speckle-server_postgres-data:/source/postgres \
  -v speckle-server_redis-data:/source/redis \
  -v speckle-server_minio-data:/source/minio \
  -v /home/speckle-user/backup:/backup \
  alpine tar xzf /backup/speckle-backup-YYYYMMDD-HHMMSS.tar.gz -C /source

docker compose -f docker-compose-deps.yml up -d
docker compose -f docker-compose-speckle.yml up -d
```

## Complete System Restore (Fresh Install)

If restoring to a fresh system or after wiping all Docker volumes (including SSL certificates), you need to regenerate SSL certificates:

```bash
cd /home/speckle-user/git/speckle-server

# 1. Remove all volumes (if not already done)
docker compose -f docker-compose-speckle.yml down
docker compose -f docker-compose-deps.yml down
docker volume prune -a -f

# 2. Restore data volumes from backup
docker run --rm \
  -v speckle-server_postgres-data:/source/postgres \
  -v speckle-server_redis-data:/source/redis \
  -v speckle-server_minio-data:/source/minio \
  -v /home/speckle-user/backup:/backup \
  alpine tar xzf /backup/speckle-backup-YYYYMMDD-HHMMSS.tar.gz -C /source

# 3. Start dependency services
docker compose -f docker-compose-deps.yml up -d

# 4. Regenerate SSL certificates and start speckle services
./utils/docker-compose-ingress/init-letsencrypt.sh
```

The init-letsencrypt.sh script will obtain new SSL certificates and start all speckle services.

## Restore from PostgreSQL-Only Backup

Restore the database from a SQL dump:

```bash
cd /home/speckle-user/git/speckle-server
docker compose -f docker-compose-speckle.yml down

# Restore database (replace filename with your backup)
gunzip -c /home/speckle-user/backup/speckle-db-YYYYMMDD.sql.gz | docker exec -i speckle-server-postgres-1 psql -U speckle speckle

docker compose -f docker-compose-speckle.yml up -d
```
