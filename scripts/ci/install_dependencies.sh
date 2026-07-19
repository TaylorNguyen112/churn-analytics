#!/usr/bin/env bash
# Install runtime + CI-only Python dependencies with strict error
# handling. Called from every workflow.

set -euo pipefail

python -m pip install --upgrade pip
pip install -r requirements.txt

if [[ -f requirements-ci.txt ]]; then
    pip install -r requirements-ci.txt
fi

echo "Installed versions:"
python --version
dbt --version || true
sqlfluff --version 2>/dev/null || true
