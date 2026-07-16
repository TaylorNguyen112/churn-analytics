/*
    Business rule:
        fct_support_event must be strictly one row per support_event_id.

    Fails when duplicate values exist. Severity: error.
*/

select
    support_event_id,
    count(*) as n_rows
from {{ ref('fct_support_event') }}
group by support_event_id
having count(*) > 1
