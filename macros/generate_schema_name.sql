{#
    Override dbt's default schema-generation behavior so a per-model
    `+schema: silver` or `+schema: gold` config maps directly to that
    Unity Catalog schema, instead of the default `<target>_<custom>`
    concatenation. This is required for the bronze / silver / gold
    medallion layout in this project.

    CI safety extension
    -------------------
    When target.name == 'ci' AND the environment variable
    DBT_CI_SCHEMA_PREFIX is set to a non-empty value, the resolved
    schema is prefixed with that value:

        +schema: silver  +  DBT_CI_SCHEMA_PREFIX=ci_pr_123
            -> ci_pr_123_silver

    This is how the GitHub Actions pull-request workflow isolates every
    CI run in its own pair of throwaway schemas (silver + gold) inside
    the dedicated CI catalog (`workspace_ci`). The dev and prod targets
    take the else branch and their behavior is identical to before.

    Belt-and-suspenders: the CI workflow also validates the prefix
    against a regex (scripts/ci/validate_environment.sh) and runs
    against a separate Unity Catalog, so a single misconfiguration
    here cannot leak into production schemas.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {%- set _ci_prefix = env_var('DBT_CI_SCHEMA_PREFIX', '') | trim -%}
        {%- if target.name == 'ci' and _ci_prefix != '' -%}
            {{ _ci_prefix }}_{{ custom_schema_name | trim }}
        {%- else -%}
            {{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
