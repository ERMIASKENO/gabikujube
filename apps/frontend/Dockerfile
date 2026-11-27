# syntax=docker/dockerfile:1.7
# Stage 1 builds static assets with Node; stage 2 is just nginx + files.
# Node, npm and source code never reach the runtime image.
ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
ARG VERSION=dev
ENV APP_VERSION=${VERSION}
RUN npm test

FROM build AS test

FROM nginxinc/nginx-unprivileged:1.30-alpine-slim AS runtime
ARG VERSION=dev
LABEL org.opencontainers.image.title="frontend" org.opencontainers.image.version="${VERSION}"
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
