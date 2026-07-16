/*
    int_customer_financial
    ----------------------
    Grain    : one row per customer_id.
    Source   : stg_telecom_customer_churn.
    Purpose  : Current-state customer financials plus reconciliation and
               validity flags. No BI aggregations. Negative values are
               preserved (source anomaly) and exposed via flags rather
               than silently corrected.
*/

with base as (

    select * from {{ ref('stg_telecom_customer_churn') }}

),

final as (

    select
        customer_id,

        monthly_charge,
        total_charges,
        total_refunds,
        total_extra_data_charges,
        total_long_distance_charges,
        total_revenue,

        -- Recomputed from components to detect drift vs source total_revenue.
        cast(
            coalesce(total_charges, 0)
            - coalesce(total_refunds, 0)
            + coalesce(total_extra_data_charges, 0)
            + coalesce(total_long_distance_charges, 0)
            as decimal(18,2)
        ) as calculated_total_revenue,

        -- Reconciliation gap. Positive = source over-reported.
        case
            when total_revenue is null then null
            else cast(
                total_revenue - (
                    coalesce(total_charges, 0)
                    - coalesce(total_refunds, 0)
                    + coalesce(total_extra_data_charges, 0)
                    + coalesce(total_long_distance_charges, 0)
                ) as decimal(18,2)
            )
        end as revenue_reconciliation_difference,

        -- Booleans copied from staging (already flagged there).
        is_total_revenue_reconciled,
        is_monthly_charge_valid,

        -- Average revenue per active month. NULL when tenure = 0 or missing.
        case
            when total_revenue is null                                 then null
            when nullif(tenure_months, 0) is null                      then null
            else cast(total_revenue / nullif(tenure_months, 0) as decimal(18,2))
        end as average_monthly_revenue,

        -- Contextual attributes helpful for financial cuts.
        tenure_months,
        contract              as contract_type,
        payment_method,
        is_paperless_billing,

        etl_ingested_at       as ingested_at,
        etl_run_id            as ingestion_batch_id

    from base

)

select * from final
