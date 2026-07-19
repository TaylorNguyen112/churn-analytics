#!/usr/bin/env bash
# Runs the appropriate dbt CI selection:
#
#   * Slim CI (state:modified+) when a production manifest is available
#     under prod-manifest/manifest.json. Deferred refs read from prod.
#
#   * Fallback: `ci_build` selector (staging + intermediate + dims,
#     no incremental facts). Used only when no production release has
#     been published yet.
#
# Both variants target the `ci` profile, whose schema routing is
# isolated to `<DBT_CI_SCHEMA_PREFIX>_silver` / `_gold` inside the
# dedicated CI catalog. Never runs against a production schema.

set -euo pipefail

# Guard: validate CI environment before we touch anything.
bash scripts/ci/validate_environment.sh

if [[ -f prod-manifest/manifest.json ]]; then
    echo "==> Slim CI (state:modified+, deferring to prod)"
    dbt build \
        --select state:modified+ \
        --defer \
        --state prod-manifest \
        --target ci \
        --fail-fast
else
    echo "==> Full CI (no production manifest available; using ci_build selector)"
    dbt build \
        --selector ci_build \
        --target ci \
        --fail-fast
fi
