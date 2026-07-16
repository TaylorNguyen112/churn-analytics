/*
    Business rule:
        fct_customer_monthly_snapshot must contain exactly one fact row
        for every intermediate row (i.e. no rows are silently dropped
        by dimension joins).

    Fails when the counts differ. Severity: error.
*/

with intermediate_count as (
    select count(*) as n from {{ ref('int_customer_monthly_360') }}
),

fact_count as (
    select count(*) as n from {{ ref('fct_customer_monthly_snapshot') }}
)

select
    i.n as intermediate_row_count,
    f.n as fact_row_count
from intermediate_count i
cross join fact_count f
where i.n <> f.n
