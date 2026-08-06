#!/usr/bin/env nix-shell
# shellcheck shell=bash
#! nix-shell -i bash
#! nix-shell -p bash grpcurl

set -euo pipefail

address=${AGENT_SANDBOX_ADDRESS:-127.0.0.1:8080}
flags=${GRPCURL_FLAGS:--plaintext}

# GRPCURL_FLAGS is shell-style whitespace-separated input. It is intended for
# grpcurl options such as "-plaintext" or "-cacert ./ca.pem".
read -r -a grpcurl_flags <<<"$flags"

rpc() {
  local operation=${*: -1}
  local -a options=()

  if (($# > 1)); then
    options=("${@:1:$#-1}")
  fi
  grpcurl "${grpcurl_flags[@]}" "${options[@]}" "$address" "$operation"
}

assert_contains() {
  local output=$1
  local expected=$2

  if [[ $output != *"$expected"* ]]; then
    printf 'Expected grpcurl output to contain %q, got:\n%s\n' \
      "$expected" "$output" >&2
    exit 1
  fi
}

services=$(rpc list)
assert_contains "$services" sandbox.v0.FilesystemService
assert_contains "$services" sandbox.v0.CommandService
assert_contains "$services" sandbox.v0.HealthService
assert_contains "$services" grpc.health.v1.Health

for service in sandbox.v0.FilesystemService sandbox.v0.CommandService; do
  response=$(rpc -d "{\"service\":\"$service\"}" grpc.health.v1.Health/Check)
  assert_contains "$response" '"status": "SERVING"'
done

response=$(rpc -d '{}' sandbox.v0.HealthService/Check)
assert_contains "$response" '"status": "SERVING_STATUS_SERVING"'

fixture_path=.agent-sandbox-smoke
fixture_content=YWdlbnQtc2FuZGJveC1zbW9rZQo=
response=$(rpc -d \
  "{\"path\":\"$fixture_path\",\"content\":\"$fixture_content\"}" \
  sandbox.v0.FilesystemService/WriteFile)
assert_contains "$response" '"bytesWritten": "20"'

response=$(rpc -d "{\"path\":\"$fixture_path\"}" \
  sandbox.v0.FilesystemService/ReadFile)
assert_contains "$response" "\"content\": \"$fixture_content\""

response=$(rpc -d \
  '{"argv":["python","-c","print(\"agent-sandbox-command\")"]}' \
  sandbox.v0.CommandService/ExecuteCommand)
assert_contains "$response" '"stdout": "YWdlbnQtc2FuZGJveC1jb21tYW5kCg=="'

printf 'gRPC checks passed for %s\n' "$address"
