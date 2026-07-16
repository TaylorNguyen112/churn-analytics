/*
    Business rule:
        fct_support_event must contain exactly one fact row for every
        staging support event.

    Fails when the counts differ. Severity: error.
*/

with staging_count as (
    select count(*) as n from {{ ref('stg_customer_support_events') }}
),

fact_count as (
    select count(*) as n from {{ ref('fct_support_event') }}
)

select
    s.n as staging_row_count,
    f.n as fact_row_count
from staging_count s
cross join fact_count f
where s.n <> f.n
