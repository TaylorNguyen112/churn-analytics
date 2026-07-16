/*
    dim_customer
    ------------
    Grain          : one row per customer (SCD Type 1).
    Source         : int_customer_profile.
    Surrogate key  : dbt_utils.generate_surrogate_key(['customer_id']).
    Unknown member : deterministic hash of the literal 'UNKNOWN'.

    SCD strategy:
      Chosen: Type 1 (overwrite in place on rebuild).
      Rationale: Profiling confirmed customer demographic attributes are
      stable between the current churn table and all monthly snapshots
      (0 tenure or contract changes observed). SCD Type 2 machinery
      (history + effective dates) would add complexity without capturing
      real change events on this dataset. If future data shows demographic
      churn, we can migrate this dim to SCD2 without changing its
      customer_key hash contract.
*/

with base as (

    select
        customer_id,
        gender,
        age,
        age_band,
        is_married,
        dependent_count,
        referral_count,
        first_join_month,
        current_tenure_months,
        current_tenure_band,
        ingested_at,
        ingestion_batch_id
    from {{ ref('int_customer_profile') }}

),

real_customers as (

    select
        {{ dbt_utils.generate_surrogate_key(['customer_id']) }} as customer_key,
        customer_id,
        gender,
        age,
        age_band,
        is_married,
        dependent_count,
        referral_count,
        first_join_month,
        current_tenure_months,
        current_tenure_band,
        false                                       as is_unknown_member,
        ingested_at                                 as created_at,
        current_timestamp()                         as dbt_loaded_at
    from base

),

unknown_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as customer_key,
        cast('UNKNOWN' as string)                             as customer_id,
        cast('Unknown' as string)                             as gender,
        cast(null as int)                                     as age,
        cast('Unknown' as string)                             as age_band,
        cast(null as boolean)                                 as is_married,
        cast(null as int)                                     as dependent_count,
        cast(null as int)                                     as referral_count,
        cast(null as date)                                    as first_join_month,
        cast(null as int)                                     as current_tenure_months,
        cast('Unknown' as string)                             as current_tenure_band,
        true                                                  as is_unknown_member,
        cast(null as timestamp)                               as created_at,
        current_timestamp()                                   as dbt_loaded_at

)

select * from real_customers
union all
select * from unknown_member
