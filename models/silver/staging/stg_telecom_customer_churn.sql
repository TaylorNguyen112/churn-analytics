{{
    config(
        materialized='view',
        tags=['silver', 'staging']
    )
}}

/*
    stg_telecom_customer_churn
    --------------------------
    Grain           : one row per customer_id (post-dedup).
    Source          : {{ source('bronze', 'telecom_customer_churn') }}
    Business key    : customer_id
    Dedup ordering  : Bronze `etl_ingested_at DESC, etl_file_row_number DESC`
                      is used INSIDE the model for row selection only.
                      Those columns are NOT projected to the Silver output.
                      Every silver/gold table keeps a uniform audit block:
                      etl_source_system + etl_job_id + etl_run_id +
                      etl_task_name + etl_updated_at.
    Data-quality
    findings kept in
    the model       :
      - `Monthly Charge` < 0 in 120 rows -> preserved, flagged via
        is_monthly_charge_valid.
      - `Churn Category` / `Churn Reason` are blank for non-churned
        customers -> converted to NULL (they carry no information).
      - `Internet Type` and some Yes/No columns are blank when the
        underlying service is absent -> converted to NULL.
      - All 7,043 rows reconcile within 0.01 on total revenue.
*/

with source as (

    select * from {{ source('bronze', 'telecom_customer_churn') }}

),

renamed as (

    select
        trim(`Customer ID`)                                         as customer_id,

        nullif(trim(Gender), '')                                    as gender,
        Age                                                         as age,
        {{ yes_no_to_boolean('Married') }}                          as is_married,
        `Number of Dependents`                                      as number_of_dependents,
        nullif(trim(City), '')                                      as city,
        lpad(cast(`Zip Code` as string), 5, '0')                    as zip_code,
        Latitude                                                    as latitude,
        Longitude                                                   as longitude,

        `Number of Referrals`                                       as number_of_referrals,
        `Tenure in Months`                                          as tenure_months,
        nullif(trim(Offer), '')                                     as offer,

        {{ yes_no_to_boolean('`Phone Service`') }}                  as has_phone_service,
        try_cast(`Avg Monthly Long Distance Charges` as decimal(18,2))
                                                                    as avg_monthly_long_distance_charges,
        {{ yes_no_to_boolean('`Multiple Lines`') }}                 as has_multiple_lines,
        {{ yes_no_to_boolean('`Internet Service`') }}               as has_internet_service,
        nullif(trim(`Internet Type`), '')                           as internet_type,
        `Avg Monthly GB Download`                                   as avg_monthly_gb_download,
        {{ yes_no_to_boolean('`Online Security`') }}                as has_online_security,
        {{ yes_no_to_boolean('`Online Backup`') }}                  as has_online_backup,
        {{ yes_no_to_boolean('`Device Protection Plan`') }}         as has_device_protection_plan,
        {{ yes_no_to_boolean('`Premium Tech Support`') }}           as has_premium_tech_support,
        {{ yes_no_to_boolean('`Streaming TV`') }}                   as has_streaming_tv,
        {{ yes_no_to_boolean('`Streaming Movies`') }}               as has_streaming_movies,
        {{ yes_no_to_boolean('`Streaming Music`') }}                as has_streaming_music,
        {{ yes_no_to_boolean('`Unlimited Data`') }}                 as has_unlimited_data,

        nullif(trim(Contract), '')                                  as contract,
        {{ yes_no_to_boolean('`Paperless Billing`') }}              as is_paperless_billing,
        nullif(trim(`Payment Method`), '')                          as payment_method,

        try_cast(`Monthly Charge`               as decimal(18,2))   as monthly_charge,
        try_cast(`Total Charges`                as decimal(18,2))   as total_charges,
        try_cast(`Total Refunds`                as decimal(18,2))   as total_refunds,
        try_cast(`Total Extra Data Charges`     as decimal(18,2))   as total_extra_data_charges,
        try_cast(`Total Long Distance Charges`  as decimal(18,2))   as total_long_distance_charges,
        try_cast(`Total Revenue`                as decimal(18,2))   as total_revenue,

        nullif(trim(`Customer Status`), '')                         as customer_status,
        nullif(trim(`Churn Category`), '')                          as churn_category,
        nullif(trim(`Churn Reason`), '')                            as churn_reason,

        -- Kept in-model for dedup ordering only, NOT projected downstream.
        etl_ingested_at                                             as _dedup_ingested_at,
        etl_file_row_number                                         as _dedup_row_number,

        -- Only Bronze etl column kept downstream.
        etl_source_system                                           as etl_source_system

    from source

),

deduplicated as (

    select
        r.*,
        row_number() over (
            partition by customer_id
            order by
                _dedup_ingested_at desc,
                _dedup_row_number  desc
        ) as _row_num
    from renamed r

),

final as (

    select
        customer_id,

        gender,
        age,
        is_married,
        number_of_dependents,
        city,
        zip_code,
        latitude,
        longitude,

        number_of_referrals,
        tenure_months,
        offer,

        has_phone_service,
        avg_monthly_long_distance_charges,
        has_multiple_lines,
        has_internet_service,
        internet_type,
        avg_monthly_gb_download,
        has_online_security,
        has_online_backup,
        has_device_protection_plan,
        has_premium_tech_support,
        has_streaming_tv,
        has_streaming_movies,
        has_streaming_music,
        has_unlimited_data,

        contract,
        is_paperless_billing,
        payment_method,

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
            when abs(
                     total_revenue
                     - (
                         coalesce(total_charges, 0)
                         - coalesce(total_refunds, 0)
                         + coalesce(total_extra_data_charges, 0)
                         + coalesce(total_long_distance_charges, 0)
                       )
                 ) <= 0.01
            then true
            else false
        end as is_total_revenue_reconciled,

        case
            when monthly_charge is null then null
            when monthly_charge >= 0    then true
            else false
        end as is_monthly_charge_valid,

        customer_status,
        churn_category,
        churn_reason,

        etl_source_system,
        {{ audit_columns() }}

    from deduplicated
    where _row_num = 1

)

select * from final
