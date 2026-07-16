/*
    Business rule:
        Every staging support event must produce exactly ONE row in the
        enriched intermediate. Fan-out (from the LEFT JOIN to
        int_customer_monthly_360) or accidental filtering are both errors.

    Fails when the enriched row count differs from the staging row count.
    Severity: error.
*/

with staging_count as (
    select count(*) as n from {{ ref('stg_customer_support_events') }}
),

enriched_count as (
    select count(*) as n from {{ ref('int_support_event_enriched') }}
)

select
    s.n as staging_row_count,
    e.n as enriched_row_count
from staging_count s
cross join enriched_count e
where s.n <> e.n
