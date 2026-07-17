/*
    dim_churn_reason
    ----------------
    Grain          : one row per (churn_category, churn_reason) + two
                     special members (Not Applicable, Unknown).
*/

with distinct_real_pairs as (

    select distinct churn_category, churn_reason
    from {{ ref('int_customer_churn_status') }}
    where customer_status = 'Churned'
      and (churn_category is not null or churn_reason is not null)

),

real_reasons as (

    select
        {{ dbt_utils.generate_surrogate_key(['churn_category', 'churn_reason']) }} as churn_reason_key,
        churn_category,
        churn_reason,
        cast('Real' as string)                                                     as member_type,
        false                                                                       as is_unknown_member,
        cast('MAVEN_SYNTHETIC' as string)                                           as etl_source_system,
        {{ audit_columns() }}
    from distinct_real_pairs

),

not_applicable_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }} as churn_reason_key,
        cast('Not Applicable' as string)                                                  as churn_category,
        cast('Not Applicable' as string)                                                  as churn_reason,
        cast('Not Applicable' as string)                                                  as member_type,
        false                                                                             as is_unknown_member,
        cast(null as string)                                                              as etl_source_system,
        {{ audit_columns() }}

),

unknown_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }} as churn_reason_key,
        cast('Unknown' as string)                                          as churn_category,
        cast('Unknown' as string)                                          as churn_reason,
        cast('Unknown' as string)                                          as member_type,
        true                                                               as is_unknown_member,
        cast(null as string)                                               as etl_source_system,
        {{ audit_columns() }}

)

select * from real_reasons
union all
select * from not_applicable_member
union all
select * from unknown_member
