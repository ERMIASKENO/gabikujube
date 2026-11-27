# syntax=docker/dockerfile:1.7
# Multi-stage JVM image:
#  1. resolve deps (cached layer, only invalidated when pom.xml changes)
#  2. build + test the fat jar
#  3. explode the jar into Spring Boot layers (deps / spring-boot-loader /
#     snapshot-deps / application) so a code change only rebuilds the small
#     top layer -> faster pushes/pulls, better registry dedup
#  4. distroless Java 21 runtime, non-root
FROM maven:3.9-eclipse-temurin-26 AS deps
WORKDIR /build
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline

FROM deps AS build
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package
RUN java -Djarmode=tools -jar target/app.jar extract --layers --launcher --destination /layers

# `mvn package` above already ran the unit tests; CI targets this stage name
FROM build AS test

FROM gcr.io/distroless/java21-debian13:nonroot AS runtime
ARG VERSION=dev
LABEL org.opencontainers.image.title="order" org.opencontainers.image.version="${VERSION}"
WORKDIR /app
COPY --from=build /layers/dependencies/ ./
COPY --from=build /layers/spring-boot-loader/ ./
COPY --from=build /layers/snapshot-dependencies/ ./
COPY --from=build /layers/application/ ./
# Container-aware JVM: size heap from the cgroup memory limit, not the node
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
