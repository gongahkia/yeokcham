#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

image=${RELAY_IMAGE:-yeokcham-relay:relay-container-test}
build_timeout=${RELAY_CONTAINER_BUILD_TIMEOUT:-900}
nginx_image=docker.io/library/nginx:1.28.0-alpine@sha256:30f1c0d78e0ad60901648be663a710bdadf19e4c10ac6782c235200619158284
project=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
payload='relay container scoped immutable payload'
object_id=$(printf %s "$payload" | sha256sum | awk '{print $1}')
prefix=yeokcham-relay-container-$$
scratch=$(mktemp -d)
network=${prefix}-network
volume=${prefix}-data
restore_volume=${prefix}-restore
relay=${prefix}-relay
proxy=${prefix}-proxy
no_volume=${prefix}-no-volume
source_status=$(git status --porcelain)

cleanup() {
  status=$?
  docker rm --force "$proxy" "$relay" "$no_volume" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$restore_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$scratch"
  exit "$status"
}

fail() {
  printf '%s\n' "relay container test: $*" >&2
  exit 1
}

trap cleanup EXIT HUP INT TERM

for tool in docker openssl curl sha256sum awk mktemp timeout sed tr grep git; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required command: $tool"
done

if [ -z "${RELAY_IMAGE+x}" ]; then
  timeout "$build_timeout" docker build \
    --file containers/relay/Containerfile --tag "$image" .
fi

docker image inspect "$image" >/dev/null
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$restore_volume" >/dev/null

issue_output=$(docker run --rm -t \
  --entrypoint /usr/local/bin/yeokcham \
  --volume "$volume:/var/lib/yeokcham-relay" \
  "$image" relay access issue --storage /var/lib/yeokcham-relay \
  --repository "$project" --scope read,write)
secret=$(printf '%s\n' "$issue_output" | tr -d '\r' \
  | sed -n 's/.*relay access secret (record now; shown once): \(v4ra1_[0-9a-f][0-9a-f]*\).*/\1/p')
[ "${#secret}" -eq 70 ] || fail "could not recover the one-time scoped test credential"

start_relay() {
  data_volume=$1
  docker rm --force "$relay" >/dev/null 2>&1 || true
  docker run --detach --name "$relay" --network "$network" \
    --network-alias relay --read-only --user 10001:10001 --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --volume "$data_volume:/var/lib/yeokcham-relay" "$image" >/dev/null
}

start_relay "$volume"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$scratch/tls.key" -out "$scratch/tls.crt" >/dev/null 2>&1
# Rootless Docker must be able to traverse this disposable certificate mount.
chmod 755 "$scratch"
chmod 644 "$scratch/tls.crt" "$scratch/tls.key"

resolve_proxy_port() {
  port=$(docker port "$proxy" 8443/tcp 2>/dev/null \
    | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')
  if [ -z "$port" ]; then
    docker logs "$proxy" >&2 || true
    fail "could not discover the proxy port"
  fi
  base=https://127.0.0.1:$port
}

start_proxy() {
  docker rm --force "$proxy" >/dev/null 2>&1 || true
  docker run --detach --name "$proxy" --network "$network" \
    --read-only --user 101:101 --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,size=8m,uid=101,gid=101,mode=0700 \
    --tmpfs /var/run:rw,noexec,nosuid,size=1m,uid=101,gid=101,mode=0755 \
    --publish 127.0.0.1:0:8443 \
    --volume "$(pwd)/containers/relay/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    --volume "$scratch/tls.crt:/run/tls/tls.crt:ro" \
    --volume "$scratch/tls.key:/run/tls/tls.key:ro" "$nginx_image" >/dev/null
  resolve_proxy_port
}

start_proxy

wait_ready() {
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    if curl --silent --show-error --insecure --fail "$base/readyz" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  docker logs "$relay" >&2 || true
  docker logs "$proxy" >&2 || true
  fail "relay never became ready through the TLS proxy"
}

wait_ready
[ "$(docker inspect --format '{{.Config.User}}' "$relay")" = 10001:10001 ] \
  || fail "relay image did not run as the fixed non-root user"
[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$relay")" = true ] \
  || fail "relay container root filesystem was writable"

object_url=$base/v1/repositories/$project/manifests/$object_id
status=$(curl --silent --show-error --insecure --output /dev/null --write-out '%{http_code}' \
  --request PUT --header "Authorization: Bearer $secret" \
  --data-binary "$payload" "$object_url")
[ "$status" = 201 ] || fail "scoped immutable upload returned $status"
received=$(curl --silent --show-error --insecure --fail \
  --header "Authorization: Bearer $secret" "$object_url")
[ "$received" = "$payload" ] || fail "scoped immutable receive changed bytes"
status=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
  --header 'Authorization: Bearer wrong-relay-access-secret' "$object_url")
[ "$status" = 401 ] || fail "invalid scoped credential returned $status"
if docker logs "$relay" 2>&1 | grep -F "$secret" >/dev/null; then
  fail "relay logs exposed the scoped credential"
fi

docker restart --time 1 "$relay" >/dev/null
wait_ready
received=$(curl --silent --show-error --insecure --fail \
  --header "Authorization: Bearer $secret" "$object_url")
[ "$received" = "$payload" ] || fail "relay volume did not persist across restart"

docker run --rm --volume "$volume:/source:ro" --volume "$scratch:/backup" \
  --entrypoint /bin/sh "$nginx_image" -ec \
  'tar -czf /backup/relay-volume.tar.gz -C /source .'
(cd "$scratch" && sha256sum relay-volume.tar.gz > relay-volume.tar.gz.sha256)
(cd "$scratch" && sha256sum --check relay-volume.tar.gz.sha256)
cp "$scratch/relay-volume.tar.gz" "$scratch/corrupt.tar.gz"
printf x >> "$scratch/corrupt.tar.gz"
sed 's/relay-volume\.tar\.gz/corrupt.tar.gz/' \
  "$scratch/relay-volume.tar.gz.sha256" > "$scratch/corrupt.tar.gz.sha256"
if (cd "$scratch" && sha256sum --check corrupt.tar.gz.sha256 >/dev/null 2>&1); then
  fail "corrupt backup passed its expected checksum"
fi

docker run --rm --volume "$restore_volume:/target" --volume "$scratch:/backup:ro" \
  --entrypoint /bin/sh "$nginx_image" -ec \
  'tar -xzf /backup/relay-volume.tar.gz -C /target'
docker rm --force "$relay" >/dev/null
start_relay "$restore_volume"
start_proxy
object_url=$base/v1/repositories/$project/manifests/$object_id
wait_ready
received=$(curl --silent --show-error --insecure --fail \
  --header "Authorization: Bearer $secret" "$object_url")
[ "$received" = "$payload" ] || fail "disposable restored relay cannot receive immutable bytes"

invalid_config=$scratch/invalid-relay.conf
printf '%s\n' 'version=1' 'unknown_key=refuse' > "$invalid_config"
if docker run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=1m \
  --entrypoint /usr/local/bin/yeokcham \
  --volume "$invalid_config:/tmp/invalid-relay.conf:ro" "$image" \
  relay serve --config /tmp/invalid-relay.conf >/dev/null 2>&1; then
  fail "unknown relay configuration key was accepted"
fi

docker run --detach --name "$no_volume" --read-only --user 10001:10001 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m "$image" >/dev/null
sleep 1
[ "$(docker inspect --format '{{.State.Running}}' "$no_volume")" = false ] \
  || fail "relay started without its writable data volume"
docker rm --force "$no_volume" >/dev/null 2>&1 || true

[ "$(git status --porcelain)" = "$source_status" ] \
  || fail "container relay test changed repository source files"
printf '%s\n' 'relay container integration passed'
