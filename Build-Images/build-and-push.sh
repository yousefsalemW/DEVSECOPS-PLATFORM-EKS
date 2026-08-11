#!/usr/bin/env bash
set -euo pipefail

REG="${REG:-alnaqib}"
TAG="${TAG:-1.1}"

b() {
  echo "==> build $1:$TAG"
  docker build -f "$2" -t "$REG/$1:$TAG" "$3"
}

s() {
  echo "==> Trivy $1:$TAG"
  trivy image \
    --timeout 15m \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    "$REG/$1:$TAG" || true
}

# Build Images
b vprofile-app images/app/Dockerfile .
b vprofile-db  images/db/Dockerfile .
b vprofile-mc  images/memcached/Dockerfile images/memcached
b vprofile-rmq images/rabbitmq/Dockerfile images/rabbitmq

# Scan Images
for i in vprofile-app vprofile-db vprofile-mc vprofile-rmq; do
  s "$i"
done

# Push Images
read -r -p "Push إلى Docker Hub بالـ tag $TAG؟ [y/N] " ok

if [ "${ok:-N}" = "y" ]; then
  for i in vprofile-app vprofile-db vprofile-mc vprofile-rmq; do
    docker push "$REG/$i:$TAG"
  done
fi
