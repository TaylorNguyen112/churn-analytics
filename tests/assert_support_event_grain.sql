/*
    Business rule:
        int_support_event_enriched must contain exactly one row per
        support_event_id (i.e. the LEFT JOIN to customer context must
        not fan out).

    Fails when duplicate support_event_id values exist.
    Severity: error.
*/

select
    support_event_id,
    count(*) as n_rows
from {{ ref('int_support_event_enriched') }}
group by support_event_id
having count(*) > 1
