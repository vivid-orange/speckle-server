# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Development Commands

```bash
# Initial setup
corepack enable
yarn
yarn build:public      # Build design system packages first
yarn build             # Build all packages

# This runs the full monorepo build with topological ordering (dependencies first).
# If you ever run into the same issue again where @speckle/shared has a partial build, you can fix it by building it first:

yarn workspace @speckle/shared build
yarn build

# Or to build just frontend-2 specifically:

yarn workspace @speckle/frontend-2 build
# The warnings about node:async_hooks and node:inspector will still appear during the frontend-2 build, but they're harmless - the build will complete successfully.

# Development
yarn dev               # Run all packages in dev mode
yarn dev:minimal       # Server + frontend-2 only (most common)
yarn dev:server        # Server only
yarn dev:frontend-2    # Frontend only
yarn dev:docker:up     # Start PostgreSQL, Redis, MinIO, Maildev containers
yarn dev:docker:down   # Stop containers

# Code quality
yarn prettier:check    # Check formatting
yarn prettier:fix      # Fix formatting
yarn cz                # Commitizen for semantic commits

# GraphQL codegen
yarn gqlgen            # Generate types for server and frontend
```

### Server-specific (packages/server)

```bash
yarn test                        # Run tests
yarn test --grep="@auth"         # Filter by test tag
yarn test:coverage               # With coverage
yarn lint                        # ESLint + TypeScript check
yarn cli db migrate              # Run database migrations
yarn cli bull monitor            # Queue monitoring UI
```

### Frontend-specific (packages/frontend-2)

```bash
yarn workspace @speckle/frontend-2 dev
yarn workspace @speckle/frontend-2 build
yarn workspace @speckle/frontend-2 gqlgen
```

## Architecture Overview

### Monorepo Structure

- **Yarn 4.5.0 workspaces** with Node.js 22.17.1
- Workspace packages use `workspace:^` references

### Main Packages

| Package                   | Description              | Tech Stack                                         |
| ------------------------- | ------------------------ | -------------------------------------------------- |
| `@speckle/server`         | GraphQL API backend      | Express, Apollo Server v4, PostgreSQL, Redis, Knex |
| `@speckle/frontend-2`     | Web application          | Nuxt 3, Vue 3 Composition API, Tailwind CSS        |
| `@speckle/viewer`         | 3D visualization library | Three.js, Rollup (published to npm)                |
| `@speckle/shared`         | Isomorphic utilities     | TypeScript, Tshy (ESM + CommonJS)                  |
| `@speckle/ui-components`  | Vue component library    | Vue 3, Storybook, Tailwind                         |
| `@speckle/tailwind-theme` | Design system            | Tailwind preset + plugin                           |

### Service Packages

- `preview-service`: Headless preview generation
- `webhook-service`: External webhook delivery
- `fileimport-service`: File parsing (Python + Node.js)

### Server Module Architecture

Server uses a module-based architecture in `/packages/server/modules/`:

- Each module has `index.ts` with `init()` and `finalize()` functions
- GraphQL schemas in `graph/schemas/`, resolvers in `graph/resolvers/`
- Key modules: auth, core, workspaces, automate, comments, dashboards

### Feature Flags

Environment variables with `FF_` prefix (e.g., `FF_WORKSPACES_MODULE_ENABLED`)

#### Auto Collaborator (`FF_AUTO_COLLABORATOR_ENABLED`)

When enabled, automatically grants `stream:contributor` access so that:
- **New users** are added to all existing projects on signup
- **New projects** have all existing users added as contributors (the project owner keeps `stream:owner`)

This removes the need to manually run `scripts/bulk-add-collaborators-db.sh` after each SSO signup. Enable by adding `FF_AUTO_COLLABORATOR_ENABLED=true` to `.env` and restarting the server.

Implementation: `packages/server/modules/core/events/autoCollaborator.ts`, registered in `packages/server/modules/core/index.ts`.

## Key Development Patterns

### TypeScript

- **Strict mode** everywhere - avoid `any` without justification
- **Type guards over assertions** - use narrowing instead of `as` casting
- **Explicit return types** for exported functions
- **Object parameters** over positional parameters for functions with multiple args

### Server: Factory Pattern for DI

```typescript
const getUserByIdFactory = (deps: { db: Knex }) => (params: { userId: string }) => {
  return deps.db.from('Users').where('userId', params.userId).first()
}
const getUserById = getUserByIdFactory({ db })
```

### Frontend: Vue 3 Composition API

- **No Vuex/Pinia** - use composables and provide/inject
- **Script setup organization**: types → props/emits → composables → refs → computed → functions → watch → lifecycle
- **Logging**: use `useLogger()`, `useSafeLogger()`, `devLog()` - never `console.log`
- **Icons**: Lucide icons only (`lucide-vue-next`) - Heroicons deprecated

### GraphQL Fragment-Based Architecture

```typescript
// Components define their data requirements via fragments
graphql(`
  fragment UserCard_User on User {
    id
    name
    email
  }
`)
// Fragment naming: {ComponentName}_{GraphQLType}
// Always include `id` field for Apollo cache
```

### Import Order

1. Node modules
2. Workspace packages (`@speckle/...`)
3. Local aliases (`~/lib/...` for frontend, `@/modules/...` for server)
4. Never use relative imports beyond same directory

### Styling (Frontend)

- Use semantic color classes from `@speckle/tailwind-theme`
- Reference `packages/tailwind-theme/src/plugin.ts` for CSS variables
- Reference `packages/tailwind-theme/src/preset.ts` for Tailwind config

## Testing

### Server Tests (Mocha + Chai)

- Tests use `@tag` naming convention (e.g., `@auth`, `@core-streams`)
- Run specific tags: `yarn test --grep="@auth"`
- Test DB setup: `yarn cli:test db migrate`

### Frontend/Shared Tests (Vitest)

```bash
yarn workspace @speckle/shared test
yarn workspace @speckle/ui-components test
```

## Git Workflow

- **Semantic commits** required - use `yarn cz` for interactive commit
- **Squash merges** to main - PR title becomes commit message
- **PR title format**: `type(scope): description` (e.g., `feat(frontend-2): add settings panel`)
- Pre-commit hooks enforce ESLint, TypeScript, and Prettier

## External Services (Docker)

| Service    | Purpose        | Ports                  |
| ---------- | -------------- | ---------------------- |
| PostgreSQL | Database       | 5432                   |
| Redis      | Cache/sessions | 6379                   |
| MinIO      | S3 storage     | 9001 (UI), 9000 (API)  |
| Maildev    | Email testing  | 1080 (UI), 1025 (SMTP) |

## Docker Deployment

### Prerequisites
- Docker Engine 28.2+ with Docker Compose v2

### Start Services
```bash
# Start dependencies (postgres, redis, minio)
docker compose -f docker-compose-deps.yml up -d

# Build images and start services (all build steps happen inside Docker)
docker compose -f docker-compose-speckle.yml up -d --build
```

### Build with Dynamic Version
To display the correct version in the UI (instead of "custom"), fetch the latest release version from GitHub:
```bash
SPECKLE_SERVER_VERSION=$(curl -s https://api.github.com/repos/specklesystems/speckle-server/releases/latest | grep tag_name | cut -d'"' -f4) \
  docker compose -f docker-compose-speckle.yml up -d --build
```

Or add an alias to `~/.bashrc` or `~/.zshrc`:
```bash
alias speckle-build='SPECKLE_SERVER_VERSION=$(curl -s https://api.github.com/repos/specklesystems/speckle-server/releases/latest | grep tag_name | cut -d"\"" -f4) docker compose -f docker-compose-speckle.yml up -d --build'
```

### Upgrade Procedure

This deployment uses a fork of the upstream Speckle repository. To upgrade to a new version:

**Step 1: Sync the fork on GitHub**
- Go to https://github.com/vivid-orange/speckle-server
- Click "Sync fork" to pull the latest upstream changes

**Step 2: Pull and merge updates**
```bash
cd /home/speckle-user/git/speckle-server
git fetch origin
git merge origin/main --no-edit
```

If there are merge conflicts, resolve them manually (typically in custom files like `docker-compose-speckle.yml` or nginx configs).

**Step 3: Run database migrations (if needed)**

Some upgrades require database migrations. Run them inside the container:
```bash
docker compose -f docker-compose-speckle.yml exec speckle-server yarn cli db migrate
```

**Step 4: Rebuild and deploy**
```bash
SPECKLE_SERVER_VERSION=X.Y.Z docker compose -f docker-compose-speckle.yml up -d --build
```

Replace `X.Y.Z` with the target version (e.g., `2.28.0`). The `--build` flag is required to rebuild images with the new code.

**Step 5: Verify the upgrade**
1. Check version in UI at https://speckle.whitbywood.com
2. Test web authentication (login/logout)
3. Test connector authentication from Revit/Rhino
4. Check logs: `docker compose -f docker-compose-speckle.yml logs speckle-server --tail=50`

**Rollback procedure**

If issues occur after upgrade:
```bash
# Stop services
docker compose -f docker-compose-speckle.yml down

# Find the previous commit
git log --oneline -10

# Revert to previous version
git reset --hard <previous-commit-hash>

# Rebuild with old version
SPECKLE_SERVER_VERSION=X.Y.Z docker compose -f docker-compose-speckle.yml up -d --build
```

### Key Configuration (docker-compose-speckle.yml)
All URL settings must use the same protocol (http or https) and match your actual server URL:

| Variable | Service | Purpose |
|----------|---------|---------|
| `CANONICAL_URL` | speckle-server | Server URL for API |
| `FRONTEND_ORIGIN` | speckle-server | Redirect URL after auth |
| `NUXT_PUBLIC_API_ORIGIN` | frontend-2 | API URL for browser |
| `NUXT_PUBLIC_BASE_URL` | frontend-2 | Base URL for frontend |
| `DOMAIN_ALIAS` | speckle-ingress | Alias domain that 301-redirects to primary `DOMAIN` |

### Object Size Limits
If you encounter "Object too large" errors when uploading large models, adjust these environment variables:

| Variable | Service | Default | Purpose |
|----------|---------|---------|---------|
| `MAX_OBJECT_SIZE_MB` | speckle-server | 100 | Maximum size for individual database objects |
| `MAX_REQUEST_BODY_SIZE_MB` | speckle-server | 100 | Maximum HTTP request body size |
| `FILE_SIZE_LIMIT_MB` | speckle-server, speckle-ingress | 100 | Maximum file upload size (also controls nginx `client_max_body_size`) |

After changing these values, rebuild the affected services:
```bash
docker compose -f docker-compose-speckle.yml up -d --build speckle-server speckle-ingress
```

### Reset Database
```bash
docker compose -f docker-compose-speckle.yml down
docker compose -f docker-compose-deps.yml down -v  # -v removes volumes
docker compose -f docker-compose-deps.yml up -d
docker compose -f docker-compose-speckle.yml up -d
```

### Domain Alias (Redirect)

To make an additional domain redirect (301) to the primary domain:

1. Point the alias domain's DNS A record to the same server IP
2. Add `DOMAIN_ALIAS=<alias-domain>` to `.env`
3. Run the init-letsencrypt script (or manually obtain a cert for the alias):
   ```bash
   ./utils/docker-compose-ingress/init-letsencrypt.sh
   ```
4. Rebuild ingress: `docker compose -f docker-compose-speckle.yml up -d --build speckle-ingress`

All requests to the alias domain will 301-redirect to the primary domain. OAuth, cookies, and CORS stay on the primary domain.

### HTTPS with Let's Encrypt

The deployment uses Let's Encrypt for SSL certificates with automatic renewal.

**Initial Setup (first time only):**
```bash
chmod +x utils/docker-compose-ingress/init-letsencrypt.sh
./utils/docker-compose-ingress/init-letsencrypt.sh
```

**Certificate Renewal:**
- Certbot container checks for renewal every 12 hours automatically
- After renewal, reload nginx to use the new certificate:
  ```bash
  docker compose -f docker-compose-speckle.yml exec speckle-ingress nginx -s reload
  ```

**Check Certificate Status:**
```bash
docker compose -f docker-compose-speckle.yml run --rm certbot certificates
```

**Verify HTTPS:**
```bash
curl -I https://speckle.whitbywood.com
curl -I http://speckle.magmaworks.co.uk  # Should 301-redirect to https://speckle.whitbywood.com
```

**Related Files:**
- `utils/docker-compose-ingress/init-letsencrypt.sh` - Certificate initialization script
- `utils/docker-compose-ingress/nginx/templates/nginx.conf.template` - Nginx SSL config

**SSL Configuration:**
The nginx config includes the following security settings:
- TLS 1.2 and 1.3 only (older protocols disabled)
- SSL session caching (10MB shared cache, 1 day timeout)
- Session tickets disabled for forward secrecy

**Security Headers:**
| Header | Value | Purpose |
|--------|-------|---------|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | Forces HTTPS for 1 year |
| `X-Content-Type-Options` | `nosniff` | Prevents MIME-sniffing |
| `X-Frame-Options` | `SAMEORIGIN` | Prevents clickjacking |

### Email Configuration

Configure SMTP in `.env`:
```bash
EMAIL_ENABLED=true
EMAIL_HOST=pro2.mail.ovh.net      # Your SMTP server
EMAIL_PORT=587
EMAIL_FROM=noreply@example.com
EMAIL_USERNAME=noreply@example.com
EMAIL_PASSWORD=your-password
EMAIL_SECURE=false                 # true for port 465 (implicit TLS)
EMAIL_REQUIRE_TLS=true             # true for port 587 (STARTTLS)
```

Test SMTP credentials:
```bash
curl -v --url "smtp://your-smtp-server:587" \
  --user "user@example.com:password" \
  --mail-from "user@example.com" \
  --mail-rcpt "test@example.com" \
  -T /dev/null --ssl-reqd
```

### Azure AD / Microsoft Entra ID Authentication

Configure SSO with Microsoft Entra ID by adding these variables to `.env`:

```bash
STRATEGY_AZURE_AD=true
AZURE_AD_ORG_NAME=Microsoft Entra ID
AZURE_AD_IDENTITY_METADATA=https://login.microsoftonline.com/<TENANT_ID>/v2.0/.well-known/openid-configuration
AZURE_AD_CLIENT_ID=<your-client-id>
AZURE_AD_ISSUER=https://login.microsoftonline.com/<TENANT_ID>/v2.0
AZURE_AD_CLIENT_SECRET=<your-client-secret>
```

**Azure Portal Requirements:**
1. Register an application in Azure Portal → App registrations
2. Set Redirect URI to `https://your-domain/auth/azure/callback` (Web platform)
3. Enable **ID tokens** under Authentication → Implicit grant
4. Add optional claim: **email** under Token configuration
5. Grant API permissions: `openid`, `profile`, `email`, `User.Read`
   - `User.Read` is required for syncing company name and profile photo from Microsoft Graph

**Troubleshooting:**
- "Invalid state" errors: Have users clear cookies or use incognito mode
- Callback URL must exactly match (no trailing slash differences)

### Bulk User Management Scripts

Scripts in `scripts/` for managing user access to projects:

| Script | Purpose | Requirements |
|--------|---------|--------------|
| `bulk-invite.sh` | Invite users by email to all projects | API token with `streams:read`, `streams:write`, `profile:read`, `users:invite` |
| `bulk-add-users.sh` | Invite registered users by userId | Same as above |
| `bulk-add-collaborators-db.sh` | Direct DB insert (no invite acceptance needed) | PostgreSQL access |

**Enable `users:invite` scope** (disabled by default):
1. Add `FF_USERS_INVITE_SCOPE_IS_PUBLIC=true` to `.env`
2. Restart speckle-server

**Usage:**
```bash
# Via API (users must accept invites)
SPECKLE_TOKEN=your-token ./scripts/bulk-add-users.sh

# Direct database (immediate access, no acceptance)
./scripts/bulk-add-collaborators-db.sh
```

## Scheduled Maintenance

### Docker Image Cleanup (cron)

A weekly cron job runs as `speckle-user` to prune dangling Docker images (old build layers from `--build` rebuilds):

```
0 3 * * 0 docker image prune -f >> /var/log/docker-prune.log 2>&1
```

- Runs every Sunday at 3am
- Only removes **dangling** (untagged) images — running containers are never affected
- Output logged to `/var/log/docker-prune.log`
- View/edit with `crontab -e` (as `speckle-user`)

**Important:** Do not use `docker system prune --volumes` — it can delete PostgreSQL/MinIO data if those containers are stopped.

### Disk Space Alerts (cron)

`scripts/check-disk.sh` checks root filesystem usage every hour and emails an alert when it exceeds 80%:

```
0 * * * * /home/speckle-user/git/speckle-server/scripts/check-disk.sh >> /var/log/check-disk.log 2>&1
```

- Sends to `t.reinhardt@whitbywood.com` via the server's SMTP config (OVH)
- Includes filesystem and Docker disk usage in the alert
- Output logged to `/var/log/check-disk.log`
- Threshold can be changed by editing `THRESHOLD=80` in the script

## IDE Setup (VSCode)

1. Open using `workspace.code-workspace` file
2. Install **Volar** extension (not Vetur)
3. **Disable** built-in "TypeScript and JavaScript Language Features" for Volar's Take Over Mode
