#!/usr/bin/env bash
# Drop the two CI schemas (`<prefix>_silver`, `<prefix>_gold`)
# associated with a closed pull request.
#
# Validation is layered so a single misconfiguration cannot delete a
# non-CI schema:
#   1. Shell-side regex check against APPROVED_CI_PREFIX_REGEX.
#   2. Shell-side check that the prefix matches ci_pr_<PR_NUMBER>.
#   3. The macros/ops/drop_ci_schemas.sql macro re-validates in Jinja.
#   4. The CI service principal only has UC grants on `workspace_ci`.
#
# Never uses wildcards. Never drops CATALOG / DATABASE. Never prints
# secret values.

set -euo pipefail

: "${DBT_CI_SCHEMA_PREFIX:?required}"
: "${APPROVED_CI_CATALOG:?required}"
: "${APPROVED_CI_PREFIX_REGEX:?required}"
: "${PR_NUMBER:?required}"

# Belt-and-suspenders (shell-side).
if [[ ! "${DBT_CI_SCHEMA_PREFIX}" =~ ${APPROVED_CI_PREFIX_REGEX} ]]; then
    echo "::error::Refusing: prefix '${DBT_CI_SCHEMA_PREFIX}' does not match ${APPROVED_CI_PREFIX_REGEX}"
    exit 1
fi
if [[ "${DBT_CI_SCHEMA_PREFIX}" != "ci_pr_${PR_NUMBER}" ]]; then
    echo "::error::Refusing: prefix '${DBT_CI_SCHEMA_PREFIX}' does not match PR number ${PR_NUMBER}"
    exit 1
fi

echo "Cleanup target:"
echo "  catalog : ${APPROVED_CI_CATALOG}"
echo "  schemas : ${DBT_CI_SCHEMA_PREFIX}_silver, ${DBT_CI_SCHEMA_PREFIX}_gold"

dbt deps
dbt run-operation drop_ci_schemas --target ci

echo "Cleanup finished."
