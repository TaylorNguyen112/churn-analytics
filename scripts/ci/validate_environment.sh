#!/usr/bin/env bash
# CI safety guard. Fails the workflow if:
#   - DBT_CI_SCHEMA_PREFIX does not match APPROVED_CI_PREFIX_REGEX
#   - DBT_CATALOG is not the approved CI catalog
#   - The resolved silver/gold schemas overlap reserved names
#
# The macros/generate_schema_name.sql override joins DBT_CI_SCHEMA_PREFIX
# with the per-model `+schema` to produce e.g. `ci_pr_123_silver`. This
# script asserts that pairing is safe before any warehouse write happens.
#
# Never prints secret values.

set -euo pipefail

: "${DBT_CI_SCHEMA_PREFIX:?DBT_CI_SCHEMA_PREFIX must be set (e.g. ci_pr_123)}"
: "${APPROVED_CI_CATALOG:?APPROVED_CI_CATALOG variable must be set on the ci environment}"
: "${APPROVED_CI_PREFIX_REGEX:?APPROVED_CI_PREFIX_REGEX must be set on the ci environment}"
: "${DBT_CATALOG:?DBT_CATALOG must be set}"
: "${DBT_SILVER_SCHEMA:=silver}"
: "${DBT_GOLD_SCHEMA:=gold}"

# 1. Prefix must match the approved regex.
if [[ ! "${DBT_CI_SCHEMA_PREFIX}" =~ ${APPROVED_CI_PREFIX_REGEX} ]]; then
    echo "::error::DBT_CI_SCHEMA_PREFIX '${DBT_CI_SCHEMA_PREFIX}' does not match ${APPROVED_CI_PREFIX_REGEX}"
    exit 1
fi

# 2. CI target must resolve to the approved CI catalog (never workspace/prod).
if [[ "${DBT_CATALOG}" != "${APPROVED_CI_CATALOG}" ]]; then
    echo "::error::DBT_CATALOG='${DBT_CATALOG}' does not equal APPROVED_CI_CATALOG='${APPROVED_CI_CATALOG}'"
    exit 1
fi

# 3. Resolved schemas must fall inside the CI namespace and never equal
#    reserved production names.
resolved_silver="${DBT_CI_SCHEMA_PREFIX}_${DBT_SILVER_SCHEMA}"
resolved_gold="${DBT_CI_SCHEMA_PREFIX}_${DBT_GOLD_SCHEMA}"

for schema in "${resolved_silver}" "${resolved_gold}"; do
    case "${schema}" in
        bronze|silver|gold|default|production|prod|dev|main)
            echo "::error::Refusing: resolved schema '${schema}' is a reserved name"
            exit 1
            ;;
        ci_pr_*)
            : # ok
            ;;
        *)
            echo "::error::Refusing: resolved schema '${schema}' is outside the CI namespace"
            exit 1
            ;;
    esac
done

echo "CI environment validated:"
echo "  catalog          : ${DBT_CATALOG}"
echo "  prefix           : ${DBT_CI_SCHEMA_PREFIX}"
echo "  resolved silver  : ${resolved_silver}"
echo "  resolved gold    : ${resolved_gold}"
