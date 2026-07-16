{#
    Standard ETL audit columns emitted at the tail of every Silver / Gold
    SELECT list. Kept identical across the entire project so downstream
    monitoring and reconciliation always find the same fields.

    Sources of each value:
      - etl_job_id      : env var DBT_ETL_JOB_ID    (Databricks job id at run time)
      - etl_run_id      : env var DBT_ETL_RUN_ID    (Databricks run id at run time)
      - etl_task_name   : env var DBT_ETL_TASK_NAME (Databricks task key at run time)
      - etl_updated_at  : Databricks current_timestamp() (server-side clock)

    In Databricks Workflows the env vars are populated by task-level
    parameters that use Databricks template substitution:
      DBT_ETL_JOB_ID    = {{ '{{job.id}}' }}
      DBT_ETL_RUN_ID    = {{ '{{job.run_id}}' }}
      DBT_ETL_TASK_NAME = {{ '{{task.name}}' }}

    For local runs the env vars fall back to 'local' / 'manual', so the
    same columns exist with clearly recognizable dev values.

    Note: `etl_source_system` is NOT included here because it is a
    per-source constant that comes from the Bronze row itself. Each
    model selects it from its own source table.
#}

{% macro audit_columns() -%}
    cast('{{ env_var('DBT_ETL_JOB_ID',    'local')  }}' as string) as etl_job_id,
    cast('{{ env_var('DBT_ETL_RUN_ID',    'local')  }}' as string) as etl_run_id,
    cast('{{ env_var('DBT_ETL_TASK_NAME', 'manual') }}' as string) as etl_task_name,
    current_timestamp()                                            as etl_updated_at
{%- endmacro %}
