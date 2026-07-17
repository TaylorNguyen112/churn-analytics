{{
    config(
        materialized='view',
        tags=['silver', 'staging']
    )
}}

/*
    stg_customer_monthly_snapshot
    -----------------------------
    Grain           : one row per (customer_id, snapshot_month), which is
                      equivalent to one row per monthly_snapshot_id.
    Source          : {{ source('bronze', 'customer_monthly_snapshot') }}
    Business key    : monthly_snapshot_id
    Dedup ordering  : source `updated_at DESC` (primary) with Bronze
                      etl_ingested_at / etl_file_row_number as tiebreakers.
                      Bronze ETL columns are used INTERNALLY only.
*/

with source as (

    select * from {{ source('bronze', 'customer_monthly_snapshot') }}

),

renamed as (

    select
        trim(monthly_snapshot_id)                              as monthly_snapshot_id,
        trim(customer_id)                                      as customer_id,

        cast(date_trunc('month', snapshot_month) as date)      as snapshot_month,

        try_cast(tenure_months  as int)                        as tenure_months,
        nullif(trim(contract_type), '')                        as contract_type,
        nullif(trim(internet_type), '')                        as internet_type,

        try_cast(monthly_charge   as decimal(18,2))            as monthly_charge,
        try_cast(monthly_revenue  as decimal(18,2))            as monthly_revenue,
        try_cast(total_revenue    as decimal(18,2))            as total_revenue,

        nullif(trim(customer_status), '')                      as customer_status,

        try_cast(updated_at as timestamp)                      as source_updated_at,
        nullif(trim(batch_id), '')                             as source_batch_id,
        nullif(trim(source_system), '')                        as source_system,

        etl_ingested_at                                        as _dedup_ingested_at,
        etl_file_row_number                                    as _dedup_row_number,
        etl_source_system                                      as etl_source_system

    from source

),

deduplicated as (

    select
        r.*,
        row_number() over (
            partition by monthly_snapshot_id
            order by
                source_updated_at   desc,
                _dedup_ingested_at  desc,
                _dedup_row_number   desc
        ) as _row_num
    from renamed r

),

final as (

    select
        monthly_snapshot_id,
        customer_id,
        snapshot_month,

        tenure_months,
        contract_type,
        internet_type,

        monthly_charge,
        monthly_revenue,
        total_revenue,

        case
            when monthly_charge is null then null
            when monthly_charge >= 0    then true
            else false
        end as is_monthly_charge_valid,

        customer_status,

        case when customer_status = 'Churned' then true
             when customer_status is null     then null
             else false end                                    as is_churned,
        case when customer_status = 'Stayed'  then true
             when customer_status is null     then null
             else false end                                    as is_stayed,
        case when customer_status = 'Joined'  then true
             when customer_status is null     then null
             else false end                                    as is_new_customer,
        case when customer_status in ('Stayed', 'Churned') then true
             when customer_status is null                  then null
             else false end                                    as is_churn_eligible,

        source_updated_at,
        source_batch_id,
        source_system,

        etl_source_system,
        {{ audit_columns() }}

    from deduplicated
    where _row_num = 1

)

select * from final
