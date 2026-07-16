/*
    dim_churn_reason
    ----------------
    Grain          : one row per (churn_category, churn_reason) pair.
    Sources        : int_customer_churn_status + int_customer_monthly_360
                     (union of all pairs actually observed).
    Surrogate key  : dbt_utils.generate_surrogate_key(['churn_category',
                     'churn_reason']) - null-safe (the macro coalesces
                     nulls to empty strings).

    Special members:
      - 'Not Applicable' / 'Not Applicable'
            Used for non-churned customer rows in the facts. Distinct from
            'Unknown' because the ABSENCE of a churn reason is a real,
            expected outcome for Stayed / Joined customers.
      - 'Unknown' / 'Unknown'
            Used defensively for CHURNED customer rows that arrive without
            a category or reason. Zero occurrences today; kept so downstream
            surrogate lookups always succeed.
*/

with distinct_real_pairs as (

    -- Every churned customer's (category, reason) pair. Because
    -- int_customer_monthly_360 sources these attributes from
    -- int_customer_churn_status directly, the current-state entity is
    -- sufficient to enumerate every (category, reason) that any fact
    -- row could reference.
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
        'Real'                                                                     as member_type,
        false                                                                       as is_unknown_member,
        current_timestamp()                                                         as dbt_loaded_at
    from distinct_real_pairs

),

not_applicable_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }} as churn_reason_key,
        cast('Not Applicable' as string)                                                  as churn_category,
        cast('Not Applicable' as string)                                                  as churn_reason,
        'Not Applicable'                                                                  as member_type,
        false                                                                             as is_unknown_member,
        current_timestamp()                                                               as dbt_loaded_at

),

unknown_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }} as churn_reason_key,
        cast('Unknown' as string)                                          as churn_category,
        cast('Unknown' as string)                                          as churn_reason,
        'Unknown'                                                          as member_type,
        true                                                               as is_unknown_member,
        current_timestamp()                                                as dbt_loaded_at

)

select * from real_reasons
union all
select * from not_applicable_member
union all
select * from unknown_member
