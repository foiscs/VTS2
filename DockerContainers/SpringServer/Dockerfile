# Stage 1: Build with official Maven image (avoids broken apt repos in Tomcat image)
FROM maven:3.8.4-openjdk-11 AS builder

WORKDIR /main
ADD pom.xml .
ADD src/ ./src/

RUN mvn clean package -DskipTests

# Stage 2: Deploy to pinned Tomcat version vulnerable to Spring4Shell
# https://hub.docker.com/layers/tomcat/library/tomcat/9.0.59-jdk11/images/sha256-383a062a98c70924fb1b1da391a054021b6448f0aa48860ae02f786aa5d4e2ad?context=explore
FROM lunasec/tomcat-9.0.59-jdk11

# containerlab exec 명령(ip addr, ip route)에 필요한 iproute2 설치
RUN apt-get update && apt-get install -y iproute2 \
    && rm -rf /var/lib/apt/lists/*

#  Copy built WAR to Tomcat webapps
COPY --from=builder /main/target/main.war /usr/local/tomcat/webapps/main.war

EXPOSE 8080
CMD ["catalina.sh", "run"]
