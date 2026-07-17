/*
    dim_customer
    ------------
    Grain          : one row per customer + one Unknown member.
    Source         : int_customer_profile.
    Surrogate key  : dbt_utils.generate_surrogate_key(['customer_id']).
    SCD            : Type 1 (see README for rationale).
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
        etl_source_system
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
        false                                                   as is_unknown_member,
        etl_source_system,
        {{ audit_columns() }}
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
        cast(null as string)                                  as etl_source_system,
        {{ audit_columns() }}

)

select * from real_customers
union all
select * from unknown_member
