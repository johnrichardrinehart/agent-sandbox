#!/usr/bin/env bash

archive=${1:?usage: publish-image OCI_ARCHIVE VERSION}
version=${2:?usage: publish-image OCI_ARCHIVE VERSION}
image=ghcr.io/johnrichardrinehart/agent-sandbox
token_file=${GHCR_TOKEN_FILE:-"$HOME/.ghcr_pat"}

if [[ ! -f $archive ]]; then
  echo "OCI archive does not exist: $archive" >&2
  exit 1
fi
if [[ ! $version =~ ^0\.0\.[0-9]+$ ]]; then
  echo "Version must have the form 0.0.n: $version" >&2
  exit 1
fi
if [[ ! -s $token_file ]]; then
  echo "GHCR token secret is unavailable: $token_file" >&2
  exit 1
fi

auth_dir=$(mktemp -d)
trap 'rm -rf "$auth_dir"' EXIT
export REGISTRY_AUTH_FILE="$auth_dir/auth.json"

# SourceHut tasks enable xtrace. Keep credentials out of logs and argv.
set +x
token=$(<"$token_file")
printf '%s' "$token" | skopeo login \
  --authfile "$REGISTRY_AUTH_FILE" \
  --username johnrichardrinehart \
  --password-stdin ghcr.io >/dev/null
unset token
set -x

skopeo copy --authfile "$REGISTRY_AUTH_FILE" \
  "docker-archive:$archive" "docker://$image:latest"
skopeo copy --authfile "$REGISTRY_AUTH_FILE" \
  "docker-archive:$archive" "docker://$image:$version"

latest_digest=$(skopeo inspect --authfile "$REGISTRY_AUTH_FILE" \
  --format '{{.Digest}}' "docker://$image:latest")
version_digest=$(skopeo inspect --authfile "$REGISTRY_AUTH_FILE" \
  --format '{{.Digest}}' "docker://$image:$version")

test -n "$latest_digest"
test "$latest_digest" = "$version_digest"
printf 'Published %s:latest and %s:%s as %s\n' \
  "$image" "$image" "$version" "$latest_digest"
