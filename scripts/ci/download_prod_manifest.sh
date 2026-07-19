#!/usr/bin/env bash
# Download the most recent production manifest.json from a
# `prod-YYYYMMDD-HHMM-<sha>` GitHub Release, so Slim CI can defer
# against it. Falls back gracefully when no production release has
# been published yet (first-time bootstrap).
#
# Writes an output variable prod_manifest_available=true|false to
# $GITHUB_OUTPUT so downstream steps can branch.

set -euo pipefail

mkdir -p prod-manifest

if ! command -v gh >/dev/null 2>&1; then
    echo "::warning::gh CLI not available; skipping production manifest download"
    echo "prod_manifest_available=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

# Pick the most recent release whose tag starts with `prod-`. Silences
# jq errors when there are no releases at all.
TAG=$(
    gh release list --limit 30 --json tagName --jq \
        '[.[] | select(.tagName | startswith("prod-"))][0].tagName' \
        2>/dev/null || true
)

if [[ -z "${TAG}" || "${TAG}" == "null" ]]; then
    echo "No 'prod-*' release found. Slim CI will fall back to the ci_build selector."
    echo "prod_manifest_available=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

echo "Downloading production manifest from release '${TAG}'..."
gh release download "${TAG}" --pattern 'manifest.json' --dir prod-manifest

if [[ -f prod-manifest/manifest.json ]]; then
    echo "prod_manifest_available=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "prod_manifest_tag=${TAG}"      >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "Slim CI enabled against ${TAG}."
else
    echo "::warning::gh release download completed but manifest.json is missing."
    echo "prod_manifest_available=false" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
