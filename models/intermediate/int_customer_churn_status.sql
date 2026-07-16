/*
    int_customer_churn_status
    -------------------------
    Grain    : one row per customer_id (current-state churn status).
    Source   : stg_telecom_customer_churn.
    Purpose  : Reusable current-state churn entity + monthly revenue lost.

    Notes    :
      - Status flags follow the source label taxonomy exactly:
            Churned / Stayed / Joined.
      - `is_churn_eligible` excludes 'Joined' customers - new customers
        cannot yet churn or stay in the current period. Downstream
        churn-rate KPIs should use this as the denominator.
      - monthly_revenue_lost_current is only counted for churned
        customers with a non-negative monthly_charge (negative charges
        represent credits and are not lost revenue).
*/

with base as (

    select * from {{ ref('stg_telecom_customer_churn') }}

),

final as (

    select
        customer_id,

        customer_status,
        churn_category,
        churn_reason,

        (customer_status = 'Churned')                       as is_churned,
        (customer_status = 'Stayed')                        as is_stayed,
        (customer_status = 'Joined')                        as is_new_customer,
        (customer_status in ('Stayed', 'Churned'))          as is_churn_eligible,

        case
            when customer_status = 'Churned'
             and monthly_charge is not null
             and monthly_charge >= 0
            then monthly_charge
            else cast(0 as decimal(18,2))
        end                                                 as monthly_revenue_lost_current,

        etl_ingested_at        as ingested_at,
        etl_run_id             as ingestion_batch_id

    from base

)

select * from final
