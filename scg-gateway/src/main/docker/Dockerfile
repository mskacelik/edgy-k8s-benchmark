ARG BASE_IMAGE=bench-base:dev

# BUILDPLATFORM: jars are architecture-independent, so the build stage runs
# natively even when the runtime stage targets another architecture.
FROM --platform=$BUILDPLATFORM registry.access.redhat.com/ubi9/openjdk-21:1.24 AS build
USER root
WORKDIR /build
COPY .mvn .mvn
COPY mvnw pom.xml ./
COPY backend-service/pom.xml backend-service/pom.xml
COPY edgy-gateway/pom.xml edgy-gateway/pom.xml
COPY scg-gateway/pom.xml scg-gateway/pom.xml
COPY scg-gateway/src scg-gateway/src
RUN microdnf install -y gzip && chmod +x mvnw
RUN --mount=type=cache,target=/root/.m2/repository \
    ./mvnw -pl scg-gateway package -DskipTests

FROM ${BASE_IMAGE}

COPY --from=build --chown=185 /build/scg-gateway/target/*.jar /deployments/app.jar

# Spring Boot bundles netty's native epoll transport and Quarkus does not, so on
# x86_64 the two gateways would sit on different syscall paths. Appended to the
# base value rather than replacing it, so heap sizing stays single-sourced.
ENV JAVA_OPTS_APPEND="$JAVA_OPTS_APPEND -Dreactor.netty.native=false"
ENV JAVA_APP_JAR="/deployments/app.jar"
