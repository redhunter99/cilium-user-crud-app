FROM mysql:8.0
ENV MYSQL_ROOT_PASSWORD=rootpass
ENV MYSQL_DATABASE=usersdb
COPY init.sql /docker-entrypoint-initdb.d/
