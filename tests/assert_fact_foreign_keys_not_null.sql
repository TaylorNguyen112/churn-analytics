/*
    Business rule:
        Every foreign key on every fact must be non-null. Unknown-member
        handling in the fact SELECT is expected to have replaced any
        unmatched natural key with the deterministic Unknown surrogate
        hash. Any null here indicates a bug in the fact SQL, not a data
        problem.

    Fails when any FK is null on either fact. Severity: error.
*/

select
    'fct_customer_monthly_snapshot' as model,
    customer_monthly_snapshot_key   as row_key,
    concat_ws('|',
        cast(customer_key         is null as string),
        cast(geography_key        is null as string),
        cast(service_profile_key  is null as string),
        cast(churn_reason_key     is null as string),
        cast(date_key             is null as string)
    ) as null_fk_flags
from {{ ref('fct_customer_monthly_snapshot') }}
where customer_key        is null
   or geography_key       is null
   or service_profile_key is null
   or churn_reason_key    is null
   or date_key            is null

union all

select
    'fct_support_event',
    support_event_key,
    concat_ws('|',
        cast(customer_key        is null as string),
        cast(geography_key       is null as string),
        cast(service_profile_key is null as string),
        cast(date_key            is null as string)
    )
from {{ ref('fct_support_event') }}
where customer_key        is null
   or geography_key       is null
   or service_profile_key is null
   or date_key            is null
