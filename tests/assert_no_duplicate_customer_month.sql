/*
    Business rule:
        The Silver customer monthly snapshot must contain exactly one
        record per (customer_id, snapshot_month). The `monthly_snapshot_id`
        column is tested for uniqueness separately in staging.yml; this
        singular test defends the alternative business grain that Gold
        marts join on.

    Severity: error.
    Returns: any (customer_id, snapshot_month) tuple that appears more
             than once in the staging model (which would indicate the
             dedup step failed or the source composite key changed).
*/

select
    customer_id,
    snapshot_month,
    count(*) as n_rows
from {{ ref('stg_customer_monthly_snapshot') }}
group by customer_id, snapshot_month
having count(*) > 1
