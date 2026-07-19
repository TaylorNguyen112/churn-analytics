#!/usr/bin/env python3
"""Write a concise dbt run summary to $GITHUB_STEP_SUMMARY.

Reads target/run_results.json (best-effort). Reports counts, execution
time, failed model/test names, and the git commit / dbt invocation ID.

Never prints secret values.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        with path.open() as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def summarize(context: str, tag: str | None) -> str:
    run_results = load_json(Path("target/run_results.json")) or {}
    metadata = run_results.get("metadata", {})
    results = run_results.get("results", [])

    dbt_version = metadata.get("dbt_version", "unknown")
    invocation_id = metadata.get("invocation_id", "unknown")
    generated_at = metadata.get("generated_at", "unknown")

    counts: dict[str, int] = {}
    passed = warned = failed = skipped = 0
    elapsed = 0.0
    failed_models: list[str] = []
    failed_tests: list[str] = []

    for r in results:
        status = r.get("status", "unknown")
        counts[status] = counts.get(status, 0) + 1
        node_id = r.get("unique_id", "")
        elapsed += float(r.get("execution_time", 0) or 0)

        if status in ("pass", "success"):
            passed += 1
        elif status == "warn":
            warned += 1
        elif status == "skipped":
            skipped += 1
        elif status in ("error", "fail", "runtime error"):
            failed += 1
            if node_id.startswith("test."):
                failed_tests.append(node_id)
            else:
                failed_models.append(node_id)

    header = "## dbt {ctx} summary".format(ctx=context)
    lines: list[str] = [
        header,
        "",
        f"- **dbt version**: `{dbt_version}`",
        f"- **invocation_id**: `{invocation_id}`",
        f"- **generated_at**: `{generated_at}`",
        f"- **commit**: `{os.environ.get('GITHUB_SHA', 'unknown')}`",
        f"- **ref**: `{os.environ.get('GITHUB_REF', 'unknown')}`",
        f"- **workflow**: `{os.environ.get('GITHUB_WORKFLOW', 'unknown')}`",
        f"- **run URL**: {os.environ.get('GITHUB_SERVER_URL', '')}/"
        f"{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/"
        f"{os.environ.get('GITHUB_RUN_ID', '')}",
    ]

    if tag:
        lines.append(f"- **release tag**: `{tag}`")

    if context == "ci":
        lines.append(
            "- **CI schema prefix**: "
            f"`{os.environ.get('DBT_CI_SCHEMA_PREFIX', 'unknown')}`"
        )
        lines.append(
            f"- **CI catalog**: `{os.environ.get('DBT_CATALOG', 'unknown')}`"
        )

    lines += [
        "",
        "### Results",
        "",
        f"- passed:  **{passed}**",
        f"- failed:  **{failed}**",
        f"- warned:  **{warned}**",
        f"- skipped: **{skipped}**",
        f"- total nodes: **{sum(counts.values())}**",
        f"- total execution time: **{elapsed:.1f}s**",
    ]

    if counts:
        lines += ["", "| status | count |", "| --- | --- |"]
        for k in sorted(counts):
            lines.append(f"| {k} | {counts[k]} |")

    if failed_models:
        lines += ["", "### Failed models"]
        for n in failed_models[:25]:
            lines.append(f"- `{n}`")
        if len(failed_models) > 25:
            lines.append(f"- ... and {len(failed_models) - 25} more")

    if failed_tests:
        lines += ["", "### Failed tests"]
        for n in failed_tests[:25]:
            lines.append(f"- `{n}`")
        if len(failed_tests) > 25:
            lines.append(f"- ... and {len(failed_tests) - 25} more")

    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", default="ci", choices=["ci", "production", "redeploy"])
    ap.add_argument("--tag", default=None)
    args = ap.parse_args()

    summary = summarize(args.context, args.tag)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as f:
            f.write(summary)
    else:
        sys.stdout.write(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
