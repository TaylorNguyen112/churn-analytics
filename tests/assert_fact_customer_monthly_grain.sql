/*
    Business rule:
        fct_customer_monthly_snapshot must be strictly one row per
        (customer_id, snapshot_month).

    Fails when duplicate tuples exist. Severity: error.
*/

select
    customer_id,
    snapshot_month,
    count(*) as n_rows
from {{ ref('fct_customer_monthly_snapshot') }}
group by customer_id, snapshot_month
having count(*) > 1
