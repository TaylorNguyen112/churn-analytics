/*
    int_customer_monthly_360
    ------------------------
    Grain     : one row per (customer_id, snapshot_month).
    Sources   : stg_customer_monthly_snapshot   (spine - historical fact)
                int_customer_profile             (stable demographics)
                int_customer_service_profile     (service booleans + key)
                int_zipcode_geography            (city, population)

    Historical vs. current attributes:
      - customer_status, contract_type, internet_type come from the
        MONTHLY SNAPSHOT (historical - "as-of" that month).
      - Yes/No service flags (streaming, security, etc.) come from the
        current customer service profile because these attributes do NOT
        exist on the monthly snapshot table. Profiling confirmed that
        contract_type / internet_type never change over a customer's
        snapshot history on the current dataset, so borrowing today's
        service booleans is safe today. If service change events ever
        arrive on the snapshot, this model MUST be revisited.

    Data-quality:
      - `data_quality_status` classifies rows for downstream monitoring
        without dropping any records.
      - Invalid records are NOT filtered out; they are visibly flagged.
*/

with snapshot_base as (

    select * from {{ ref('stg_customer_monthly_snapshot') }}

),

customer_profile as (

    select
        customer_id,
        gender,
        age,
        age_band,
        is_married,
        dependent_count,
        referral_count,
        zip_code,
        first_join_month
    from {{ ref('int_customer_profile') }}

),

customer_churn_terminal as (

    -- Customer-level terminal churn attributes. The fact "activates"
    -- these only for months where is_churned = true so historical
    -- rows (before the churn month) do not leak future information.
    select
        customer_id,
        churn_category,
        churn_reason
    from {{ ref('int_customer_churn_status') }}

),

service_profile as (

    select
        customer_id,
        service_profile_key,
        offer,
        has_phone_service,
        has_multiple_lines,
        has_internet_service,
        has_online_security,
        has_online_backup,
        has_device_protection,
        has_premium_tech_support,
        has_streaming_tv,
        has_streaming_movies,
        has_streaming_music,
        has_unlimited_data,
        service_count,
        has_any_streaming_service,
        has_streaming_bundle,
        has_security_bundle
    from {{ ref('int_customer_service_profile') }}

),

geography as (

    select
        zip_code,
        city,
        latitude,
        longitude,
        population,
        is_population_valid
    from {{ ref('int_zipcode_geography') }}

),

joined as (

    select
        s.monthly_snapshot_id,
        s.customer_id,
        s.snapshot_month,

        s.tenure_months,
        case
            when s.tenure_months is null then 'Unknown'
            when s.tenure_months <= 6    then '0-6 months'
            when s.tenure_months <= 12   then '7-12 months'
            when s.tenure_months <= 24   then '13-24 months'
            when s.tenure_months <= 48   then '25-48 months'
            else                              '49+ months'
        end as tenure_band,

        -- historical status attributes (from the snapshot itself)
        s.customer_status,
        s.contract_type,
        s.internet_type,
        s.is_churned,
        s.is_stayed,
        s.is_new_customer,
        s.is_churn_eligible,

        -- customer-level terminal churn attribution
        cct.churn_category,
        cct.churn_reason,

        -- historical financials
        s.monthly_charge,
        s.monthly_revenue,
        s.total_revenue,
        s.is_monthly_charge_valid,

        -- demographics (stable across months for a given customer)
        cp.gender,
        cp.age,
        cp.age_band,
        cp.is_married,
        cp.dependent_count,
        cp.referral_count,
        cp.first_join_month,

        -- service profile (current-state - see model header)
        sp.service_profile_key,
        sp.offer,
        sp.has_phone_service,
        sp.has_multiple_lines,
        sp.has_internet_service,
        sp.has_online_security,
        sp.has_online_backup,
        sp.has_device_protection,
        sp.has_premium_tech_support,
        sp.has_streaming_tv,
        sp.has_streaming_movies,
        sp.has_streaming_music,
        sp.has_unlimited_data,
        sp.service_count,
        sp.has_any_streaming_service,
        sp.has_streaming_bundle,
        sp.has_security_bundle,

        -- geography
        cp.zip_code,
        g.city,
        g.latitude,
        g.longitude,
        g.population,
        g.is_population_valid,

        -- audit
        s.source_updated_at,
        s.source_batch_id,
        s.source_system,
        s.etl_ingested_at        as ingested_at,
        s.etl_run_id             as ingestion_batch_id,
        s.etl_source_file        as source_file

    from snapshot_base s
    left join customer_profile         cp  on cp.customer_id  = s.customer_id
    left join customer_churn_terminal  cct on cct.customer_id = s.customer_id
    left join service_profile          sp  on sp.customer_id  = s.customer_id
    left join geography                g   on g.zip_code      = cp.zip_code

),

final as (

    select
        monthly_snapshot_id,
        customer_id,
        snapshot_month,

        tenure_months,
        tenure_band,

        customer_status,
        contract_type,
        internet_type,
        is_churned,
        is_stayed,
        is_new_customer,
        is_churn_eligible,

        churn_category,
        churn_reason,

        gender,
        age,
        age_band,
        is_married,
        dependent_count,
        referral_count,
        first_join_month,

        service_profile_key,
        offer,
        has_phone_service,
        has_multiple_lines,
        has_internet_service,
        has_online_security,
        has_online_backup,
        has_device_protection,
        has_premium_tech_support,
        has_streaming_tv,
        has_streaming_movies,
        has_streaming_music,
        has_unlimited_data,
        service_count,
        has_any_streaming_service,
        has_streaming_bundle,
        has_security_bundle,

        zip_code,
        city,
        latitude,
        longitude,
        population,
        is_population_valid,

        monthly_charge,
        monthly_revenue,
        total_revenue,
        is_monthly_charge_valid,

        case
            when is_churned = true
             and monthly_charge is not null
             and monthly_charge >= 0
            then monthly_charge
            else cast(0 as decimal(18,2))
        end                                              as monthly_revenue_lost,

        -- Additive counting flags (facts multiply-and-sum these).
        1                                                as customer_count,
        case when is_churn_eligible = true then 1 else 0 end as eligible_customer_count,
        case when is_churned         = true then 1 else 0 end as churned_customer_count,
        case when is_stayed          = true then 1 else 0 end as stayed_customer_count,
        case when is_new_customer    = true then 1 else 0 end as new_customer_count,

        -- Combined data-quality classifier. Order matters: first match wins.
        case
            when customer_id     is null                     then 'MISSING_CUSTOMER_ID'
            when snapshot_month  is null                     then 'INVALID_SNAPSHOT_MONTH'
            when monthly_charge is not null
             and monthly_charge < 0                          then 'INVALID_MONTHLY_CHARGE'
            when zip_code       is null                      then 'MISSING_ZIP_CODE'
            else 'VALID'
        end                                              as data_quality_status,

        source_updated_at,
        source_batch_id,
        source_system,
        ingested_at,
        ingestion_batch_id,
        source_file

    from joined

)

select * from final
