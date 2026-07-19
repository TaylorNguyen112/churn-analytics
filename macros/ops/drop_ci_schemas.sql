{#
    drop_ci_schemas
    ---------------
    Deletes the two CI schemas (`<prefix>_silver`, `<prefix>_gold`)
    associated with a closed pull request. Invoked by the cleanup
    workflow via:

        dbt run-operation drop_ci_schemas --target ci

    Safety:
      1. `DBT_CI_SCHEMA_PREFIX` must match APPROVED_CI_PREFIX_REGEX
         (default `^ci_pr_[0-9]+$`).
      2. Refuses to drop reserved names (bronze / silver / gold /
         default / production / prod / dev / main).
      3. Runs `DROP SCHEMA IF EXISTS ... CASCADE` scoped to one schema
         at a time. Never uses wildcards. Never DROP CATALOG / DATABASE.
      4. Uses the CI target profile, so the CI service principal's UC
         grants (write only on `workspace_ci`) provide an additional
         guardrail: even if this macro were called with a bad prefix,
         the SP could not touch production schemas.
#}

{% macro drop_ci_schemas() %}

    {% set prefix  = env_var('DBT_CI_SCHEMA_PREFIX') %}
    {% set catalog = env_var('APPROVED_CI_CATALOG') %}
    {% set regex   = env_var('APPROVED_CI_PREFIX_REGEX', '^ci_pr_[0-9]+$') %}

    {% if not modules.re.match(regex, prefix) %}
        {{ exceptions.raise_compiler_error(
            "Refusing to drop schemas: prefix '" ~ prefix ~
            "' does not match " ~ regex
        ) }}
    {% endif %}

    {% set _reserved = ['bronze', 'silver', 'gold', 'default',
                        'production', 'prod', 'dev', 'main'] %}

    {% for suffix in ['silver', 'gold'] %}

        {% set schema = prefix ~ '_' ~ suffix %}

        {% if schema in _reserved %}
            {{ exceptions.raise_compiler_error(
                "Refusing to drop reserved schema '" ~ schema ~ "'"
            ) }}
        {% endif %}

        {% if not modules.re.match('^ci_pr_[0-9]+_(silver|gold)$', schema) %}
            {{ exceptions.raise_compiler_error(
                "Refusing to drop schema outside CI namespace: '" ~ schema ~ "'"
            ) }}
        {% endif %}

        {% do log("Dropping CI schema " ~ catalog ~ "." ~ schema, info=true) %}

        {% set drop_sql -%}
            drop schema if exists `{{ catalog }}`.`{{ schema }}` cascade
        {%- endset %}

        {% do run_query(drop_sql) %}

    {% endfor %}

    {% do log("CI schema cleanup complete for prefix " ~ prefix, info=true) %}

{% endmacro %}
