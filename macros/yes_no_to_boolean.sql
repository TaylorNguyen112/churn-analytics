{#
    Convert typical Yes/No text values into a boolean.

    Accepted true values:  Yes, Y, True, 1
    Accepted false values: No, N, False, 0

    Anything else (unexpected value, blank string, NULL) returns NULL,
    so unknown values are never silently coerced.

    The macro handles inconsistent casing and surrounding whitespace.
#}

{% macro yes_no_to_boolean(column) -%}
    case
        when lower(trim(cast({{ column }} as string))) in ('yes', 'y', 'true',  '1') then true
        when lower(trim(cast({{ column }} as string))) in ('no',  'n', 'false', '0') then false
        else null
    end
{%- endmacro %}
