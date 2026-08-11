FROM mysql:8.0.43
LABEL maintainer="ALnaqib" org.opencontainers.image.title="vprofile-db"
# رقّع الـ OS + شيل mysqlsh (مش محتاجينه في container بيقدّم DB) → يقلّل ثغرات
RUN microdnf update -y && microdnf clean all && rm -rf /usr/lib/mysqlsh
ENV MYSQL_DATABASE=accounts
COPY src/main/resources/db_backup.sql /docker-entrypoint-initdb.d/10-db_backup.sql
EXPOSE 3306
