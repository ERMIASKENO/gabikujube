# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Multi-stage Go image: ~10 MB, no shell, no package manager, runs as non-root.
# Base images are referenced by tag here for readability; in CI Dependabot
# keeps them pinned to digests (see .github/dependabot.yml, docker ecosystem).
# ---------------------------------------------------------------------------
ARG GO_VERSION=1.27

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS deps
WORKDIR /src
COPY go.mod ./
# Cache module downloads across builds (BuildKit cache mount, not a layer)
RUN --mount=type=cache,target=/go/pkg/mod go mod download

FROM deps AS test
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    go vet ./... && CGO_ENABLED=0 go test ./...

FROM deps AS build
ARG TARGETOS TARGETARCH
ARG VERSION=dev
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

# distroless/static: CA certs + tzdata + /etc/passwd with uid 65532 (nonroot)
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ARG VERSION=dev
LABEL org.opencontainers.image.title="product-catalog" \
      org.opencontainers.image.source="https://github.com/ERMIASKENO/gabikujube" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=build /out/app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
