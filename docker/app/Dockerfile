# Multi-stage: build the WAR with Maven, run on Tomcat.
# (Pre-built image also available: alnaqib/vprofile-app:1.0)
FROM maven:3.9-eclipse-temurin-11 AS build
WORKDIR /src
COPY . .
RUN mvn -B clean package

FROM tomcat:9-jdk11
RUN rm -rf /usr/local/tomcat/webapps/ROOT
COPY --from=build /src/target/*.war /usr/local/tomcat/webapps/ROOT.war
EXPOSE 8080
