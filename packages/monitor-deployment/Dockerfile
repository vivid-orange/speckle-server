# NOTE: Docker context must be the git root directory, to include the shared directory
ARG NODE_ENV=production

FROM node:22-bookworm-slim@sha256:d415caac2f1f77b98caaf9415c5f807e14bc8d7bdea62561ea2fef4fbd08a73c AS build-stage

WORKDIR /speckle-server

# Download tini
ARG TINI_VERSION=v0.19.0
RUN apt-get update -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
     --no-install-recommends \
     ca-certificates=20230311+deb12u1 \
     curl=7.88.1-10+deb12u14 \
    && curl -fsSL https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini -o /usr/bin/tini \
    && chmod +x /usr/bin/tini \
    && apt-get remove -y curl \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Consume the ARG from the global scope
ARG NODE_ENV
ENV NODE_ENV=${NODE_ENV}

WORKDIR /speckle-server

COPY .yarnrc.yml .
COPY .yarn ./.yarn
COPY package.json yarn.lock ./

# Only copy in the relevant package.json files for the dependencies
COPY packages/shared/package.json ./packages/shared/
COPY packages/monitor-deployment/package.json ./packages/monitor-deployment/

RUN PUPPETEER_SKIP_DOWNLOAD=true PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 yarn workspaces focus -A

# Only copy in the relevant source files for the dependencies
COPY packages/shared ./packages/shared/
COPY packages/monitor-deployment ./packages/monitor-deployment/

RUN yarn workspaces foreach -Wt run build

WORKDIR /speckle-server/packages/monitor-deployment
RUN PUPPETEER_SKIP_DOWNLOAD=true PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 yarn workspaces focus --production

FROM gcr.io/distroless/nodejs22-debian12:nonroot@sha256:13593b7570658e8477de39e2f4a1dd25db2f836d68a0ba771251572d23bb4f8e AS production-stage

# Consume the ARG from the global scope
ARG NODE_ENV
ENV NODE_ENV=${NODE_ENV}

WORKDIR /speckle-server
COPY --link --from=build-stage /usr/bin/tini /usr/bin/tini
COPY --link --from=build-stage /speckle-server/packages/shared ./packages/shared
COPY --link --from=build-stage /speckle-server/packages/monitor-deployment ./packages/monitor-deployment
COPY --link --from=build-stage /speckle-server/node_modules ./node_modules

WORKDIR /speckle-server/packages/monitor-deployment

ENTRYPOINT [ "tini", "--", "/nodejs/bin/node", "--loader=./dist/src/aliasLoader.js", "./bin/www.js" ]
