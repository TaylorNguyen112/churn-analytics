/*
    Business rule:
        int_customer_monthly_360 must contain at most one row per
        (customer_id, snapshot_month).

    Fails when duplicate (customer_id, snapshot_month) tuples exist.
    Severity: error.
*/

select
    customer_id,
    snapshot_month,
    count(*) as n_rows
from {{ ref('int_customer_monthly_360') }}
group by customer_id, snapshot_month
having count(*) > 1
