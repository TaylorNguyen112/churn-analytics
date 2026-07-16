/*
    int_customer_service_profile
    ----------------------------
    Grain      : one row per customer_id (Design A).
    Source     : stg_telecom_customer_churn.
    Purpose    : Present each customer's service configuration and derived
                 bundle flags. Used both by fct_customer_monthly_snapshot
                 (via int_customer_monthly_360) and by dim_service_profile
                 (which selects DISTINCT on the natural attribute set).
    Decision   : Customer grain preferred over "one row per configuration"
                 because it is directly consumable by every downstream
                 model without an additional join back to customers.

    Design notes:
      - service_profile_key is a stable surrogate hash over the full
        service attribute set. The same expression is used in
        dim_service_profile so keys reconcile automatically.
      - Booleans are coalesced to false before summing so NULL (unknown /
        no underlying service) does not silently inflate service_count.
        This affects service_count when e.g. Streaming TV is NULL because
        the customer has no internet service.
*/

with base as (

    select * from {{ ref('stg_telecom_customer_churn') }}

),

renamed as (

    select
        customer_id,
        offer,
        contract                        as contract_type,
        internet_type,

        has_phone_service,
        has_multiple_lines,
        has_internet_service,
        has_online_security,
        has_online_backup,
        has_device_protection_plan      as has_device_protection,
        has_premium_tech_support,
        has_streaming_tv,
        has_streaming_movies,
        has_streaming_music,
        has_unlimited_data,

        avg_monthly_gb_download,
        avg_monthly_long_distance_charges as avg_monthly_long_distance_charge,

        etl_ingested_at                 as ingested_at,
        etl_run_id                      as ingestion_batch_id

    from base

),

derived as (

    select
        r.*,

        -- Additive service count. NULL flags are treated as 0 (unknown /
        -- underlying service unavailable). See model header for rationale.
        (
            case when has_phone_service           = true then 1 else 0 end
          + case when has_multiple_lines          = true then 1 else 0 end
          + case when has_internet_service        = true then 1 else 0 end
          + case when has_online_security         = true then 1 else 0 end
          + case when has_online_backup           = true then 1 else 0 end
          + case when has_device_protection       = true then 1 else 0 end
          + case when has_premium_tech_support    = true then 1 else 0 end
          + case when has_streaming_tv            = true then 1 else 0 end
          + case when has_streaming_movies        = true then 1 else 0 end
          + case when has_streaming_music         = true then 1 else 0 end
          + case when has_unlimited_data          = true then 1 else 0 end
        )                                                       as service_count,

        (
            coalesce(has_streaming_tv,     false)
         or coalesce(has_streaming_movies, false)
         or coalesce(has_streaming_music,  false)
        )                                                       as has_any_streaming_service,

        (
            case when has_streaming_tv     = true then 1 else 0 end
          + case when has_streaming_movies = true then 1 else 0 end
          + case when has_streaming_music  = true then 1 else 0 end
        ) >= 2                                                  as has_streaming_bundle,

        (
            coalesce(has_online_security,   false)
        and coalesce(has_online_backup,     false)
        and coalesce(has_device_protection, false)
        )                                                       as has_security_bundle

    from renamed r

),

final as (

    select
        customer_id,

        -- Stable surrogate key over the entire natural service profile.
        -- Used by dim_service_profile and by facts joining to that dim.
        {{ dbt_utils.generate_surrogate_key([
            'offer',
            'contract_type',
            'internet_type',
            'has_phone_service',
            'has_multiple_lines',
            'has_internet_service',
            'has_online_security',
            'has_online_backup',
            'has_device_protection',
            'has_premium_tech_support',
            'has_streaming_tv',
            'has_streaming_movies',
            'has_streaming_music',
            'has_unlimited_data'
        ]) }} as service_profile_key,

        offer,
        contract_type,
        internet_type,

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

        avg_monthly_gb_download,
        avg_monthly_long_distance_charge,

        service_count,
        has_any_streaming_service,
        has_streaming_bundle,
        has_security_bundle,

        ingested_at,
        ingestion_batch_id

    from derived

)

select * from final
