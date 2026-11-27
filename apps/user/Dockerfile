# syntax=docker/dockerfile:1.7
# Multi-stage Node image: install with dev deps -> test -> prune to prod deps
# -> copy into distroless (no shell, no npm, non-root).
ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts

FROM deps AS test
COPY . .
RUN npm test

FROM deps AS prod-deps
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts

FROM gcr.io/distroless/nodejs${NODE_VERSION}-debian13:nonroot AS runtime
ARG VERSION=dev
ENV NODE_ENV=production APP_VERSION=${VERSION}
LABEL org.opencontainers.image.title="user" org.opencontainers.image.version="${VERSION}"
WORKDIR /app
COPY --from=prod-deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER 65532:65532
EXPOSE 8080
# distroless node image's entrypoint is already "node"
CMD ["src/server.js"]
