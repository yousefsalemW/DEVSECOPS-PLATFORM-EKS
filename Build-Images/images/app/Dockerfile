FROM maven:3.9.9-eclipse-temurin-11 AS build
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
ARG DB_HOST=db01
ARG MC_HOST=mc01
ARG RMQ_HOST=rmq01
RUN set -eux; p=src/main/resources/application.properties; \
    sed -i "s#jdbc:mysql://db01:#jdbc:mysql://${DB_HOST}:#"                   "$p"; \
    sed -i "s#memcached.active.host=mc01#memcached.active.host=${MC_HOST}#"   "$p"; \
    sed -i "s#memcached.standBy.host=mc01#memcached.standBy.host=${MC_HOST}#" "$p"; \
    sed -i "s#rabbitmq.address=rmq01#rabbitmq.address=${RMQ_HOST}#"           "$p"; \
    mvn -q -B clean package -DskipTests
FROM tomcat:9.0-jre11-temurin-jammy
LABEL maintainer="ALnaqib" org.opencontainers.image.title="vprofile-app"
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --from=build /workspace/target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war
RUN groupadd -r tomcat && useradd -r -g tomcat -d /usr/local/tomcat tomcat && chown -R tomcat:tomcat /usr/local/tomcat
USER tomcat
EXPOSE 8080
CMD ["catalina.sh","run"]
