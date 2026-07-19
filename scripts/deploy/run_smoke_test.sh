#!/usr/bin/env bash
# Post-deploy smoke test. Non-destructive.
#
# Two lightweight checks against the production target:
#   1. `dbt compile --selector smoke` - deploys' Jinja must render and
#      resolve every ref/source referenced by the canonical fact + dim
#      models. Does not touch the warehouse.
#   2. `dbt test --selector critical_tests` - queries the deployed
#      production tables to confirm grain, FK integrity, and
#      fact-vs-source reconciliation still hold after deploy.
#
# We never run `dbt build --full-refresh` here. Data rebuild belongs
# to the scheduled Databricks Workflow.

set -euo pipefail

echo "==> dbt compile (smoke selector, prod target)"
dbt compile --selector smoke --target prod

echo "==> dbt test (critical_tests selector, prod target)"
dbt test --selector critical_tests --target prod
