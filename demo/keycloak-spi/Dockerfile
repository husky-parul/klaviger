# Stage 1: Build the SPI JAR with Maven
FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build
COPY pom.xml .
# Download dependencies first (cacheable layer)
RUN mvn dependency:go-offline -q
COPY src/ src/
RUN mvn package -q -DskipTests

# Stage 2: Layer onto Keycloak 26.5.2 (same version as act-claim-spi)
# This version supports client-auth-federated and kubernetes-service-accounts
FROM quay.io/keycloak/keycloak:26.5.2
COPY --from=builder /build/target/keycloak-agentic-spi-1.0.0-SNAPSHOT.jar /opt/keycloak/providers/
ENV KC_FEATURES=client-auth-federated,kubernetes-service-accounts,token-exchange-standard
RUN /opt/keycloak/bin/kc.sh build
