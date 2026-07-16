{#
    Override dbt's default schema-generation behavior so a per-model
    `+schema: silver` or `+schema: gold` config maps directly to that
    Unity Catalog schema, instead of the default `<target>_<custom>`
    concatenation. This is required for the bronze / silver / gold
    medallion layout in this project.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
