/*
    int_customer_profile
    --------------------
    Grain      : one row per customer_id.
    Sources    : stg_telecom_customer_churn (demographics, tenure, zip)
                 stg_customer_monthly_snapshot (latest snapshot_month
                     used to derive first_join_month).

    first_join_month is an ESTIMATE derived from latest_snapshot_month -
    (tenure_months - 1) months. Documented as an estimate because the
    source has no explicit join date.
*/

with churn as (

    select * from {{ ref('stg_telecom_customer_churn') }}

),

latest_snapshot as (

    select
        customer_id,
        max(snapshot_month) as latest_snapshot_month
    from {{ ref('stg_customer_monthly_snapshot') }}
    group by customer_id

),

joined as (

    select
        c.customer_id,
        c.gender,
        c.age,
        c.is_married,
        c.number_of_dependents         as dependent_count,
        c.number_of_referrals          as referral_count,
        c.zip_code,
        c.tenure_months                as current_tenure_months,
        c.etl_source_system            as etl_source_system,
        l.latest_snapshot_month
    from churn c
    left join latest_snapshot l on l.customer_id = c.customer_id

),

final as (

    select
        customer_id,

        gender,
        age,
        case
            when age is null    then 'Unknown'
            when age < 30       then '18-29'
            when age < 45       then '30-44'
            when age < 60       then '45-59'
            else                     '60+'
        end                                                     as age_band,

        is_married,
        dependent_count,
        referral_count,
        zip_code,

        case
            when latest_snapshot_month is null
              or current_tenure_months  is null then null
            else add_months(latest_snapshot_month, -(current_tenure_months - 1))
        end                                                     as first_join_month,

        current_tenure_months,
        case
            when current_tenure_months is null then 'Unknown'
            when current_tenure_months <= 6    then '0-6 months'
            when current_tenure_months <= 12   then '7-12 months'
            when current_tenure_months <= 24   then '13-24 months'
            when current_tenure_months <= 48   then '25-48 months'
            else                                    '49+ months'
        end                                                     as current_tenure_band,

        etl_source_system,
        {{ audit_columns() }}

    from joined

)

select * from final
