/*
    Source anomaly (deliberately retained, not corrected in Silver):

        Some customers and some monthly snapshots have a negative
        `Monthly Charge` / `monthly_charge`. Profiling counts:
            stg_telecom_customer_churn      -> 120 rows
            stg_customer_monthly_snapshot   -> 1,078 rows

        These represent legitimate account credits / adjustments in the
        source system and must NOT be silently coerced. Downstream Gold
        models should decide how to treat them (e.g. clamp to zero for
        revenue KPIs, keep as-is for auditability).

    Severity: warn.
    Returns: every row where the validity flag is FALSE across BOTH
             staging models, so the analyst sees the current volume on
             every dbt run.
*/

{{ config(severity='warn') }}

select
    'stg_telecom_customer_churn'  as model,
    customer_id                   as entity_id,
    monthly_charge                as monthly_charge
from {{ ref('stg_telecom_customer_churn') }}
where is_monthly_charge_valid = false

union all

select
    'stg_customer_monthly_snapshot' as model,
    monthly_snapshot_id             as entity_id,
    monthly_charge                  as monthly_charge
from {{ ref('stg_customer_monthly_snapshot') }}
where is_monthly_charge_valid = false
