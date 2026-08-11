FROM memcached:1.6.38-alpine
LABEL maintainer="ALnaqib" org.opencontainers.image.title="vprofile-mc"
USER root
RUN apk update && apk upgrade --no-cache
USER memcache
EXPOSE 11211
CMD ["memcached","-m","64","-l","0.0.0.0","-p","11211"]
