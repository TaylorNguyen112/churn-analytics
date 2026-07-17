/*
    int_customer_financial
    ----------------------
    Grain    : one row per customer_id.
    Source   : stg_telecom_customer_churn.
    Purpose  : Current-state customer financials plus reconciliation and
               validity flags. Preserves negative values (source
               anomalies) and exposes quality flags rather than silently
               correcting.
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

        cast(
            coalesce(total_charges, 0)
            - coalesce(total_refunds, 0)
            + coalesce(total_extra_data_charges, 0)
            + coalesce(total_long_distance_charges, 0)
            as decimal(18,2)
        ) as calculated_total_revenue,

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

        is_total_revenue_reconciled,
        is_monthly_charge_valid,

        case
            when total_revenue is null                                 then null
            when nullif(tenure_months, 0) is null                      then null
            else cast(total_revenue / nullif(tenure_months, 0) as decimal(18,2))
        end as average_monthly_revenue,

        tenure_months,
        contract              as contract_type,
        payment_method,
        is_paperless_billing,

        etl_source_system,
        {{ audit_columns() }}

    from base

)

select * from final
