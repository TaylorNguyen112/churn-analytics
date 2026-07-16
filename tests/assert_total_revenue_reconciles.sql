/*
    Business rule:
        Total Revenue at the customer level must equal:
            total_charges
            - total_refunds
            + total_extra_data_charges
            + total_long_distance_charges
        within a rounding tolerance of 0.01.

    Source profiling on the current Bronze snapshot showed ALL 7,043 rows
    reconcile perfectly. Any future violation likely indicates a source
    calculation change and should block the build.

    Severity: error.
    Returns: only rows that VIOLATE the reconciliation rule.
*/

select
    customer_id,
    total_revenue,
    calculated_total_revenue,
    abs(total_revenue - calculated_total_revenue) as revenue_gap
from {{ ref('stg_telecom_customer_churn') }}
where total_revenue is not null
  and abs(total_revenue - calculated_total_revenue) > 0.01
