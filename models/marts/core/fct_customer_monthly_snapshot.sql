{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='customer_monthly_snapshot_key',
        on_schema_change='sync_all_columns',
        tags=['gold', 'core', 'fact']
    )
}}

/*
    fct_customer_monthly_snapshot
    -----------------------------
    Grain              : one row per (customer_id, snapshot_month).
    Source             : int_customer_monthly_360 (spine)
                       + dim_customer, dim_geography, dim_service_profile,
                         dim_churn_reason, dim_date (foreign-key lookups).
    Materialization    : Delta MERGE (incremental_strategy='merge'),
                         unique_key='customer_monthly_snapshot_key'.

    Why MERGE:
      Historical months can receive late-arriving corrections (source
      updated_at can bump on prior snapshots). MERGE upserts by the
      surrogate key, so reruns are idempotent and corrections propagate
      without duplicates.

    Watermark strategy:
      Track the maximum of (source_updated_at, ingested_at) already
      loaded. Reload rows whose max is >= that watermark - 2 days.
      This 2-day lookback absorbs upstream commits arriving out of order
      without a full refresh.

      NOTE: We do NOT use max(snapshot_month) as the watermark, because
      snapshot_month is the calendar dimension of the fact - it does not
      move forward when a prior month is corrected. `source_updated_at`
      moves in step with real changes.

    Full refresh:
      A `dbt run --full-refresh` rebuilds every row from scratch, so
      recovery from data-quality incidents is a one-command operation.

    Unknown-member handling:
      Every FK is COALESCEd to the deterministic 'UNKNOWN' surrogate hash
      so the fact never carries a NULL foreign key. Referential integrity
      is asserted separately by dbt tests, and unmatched natural keys
      surface via `is_customer_matched` etc. Current-data profiling shows
      zero orphans across all FKs.
*/

with source_360 as (

    select * from {{ ref('int_customer_monthly_360') }}

    {% if is_incremental() %}
    where greatest(
              coalesce(source_updated_at, cast('1900-01-01' as timestamp)),
              coalesce(ingested_at,       cast('1900-01-01' as timestamp))
          ) >= (
              select date_sub(
                  coalesce(
                      max(greatest(
                          coalesce(source_updated_at, cast('1900-01-01' as timestamp)),
                          coalesce(ingested_at,       cast('1900-01-01' as timestamp))
                      )),
                      cast('1900-01-01' as timestamp)
                  ),
                  2
              )
              from {{ this }}
          )
    {% endif %}

),

-- Unknown-member surrogate keys (evaluated once per model run)
unknown_keys as (

    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_customer_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_geography_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_service_profile_key,
        {{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }}     as not_applicable_reason_key,
        {{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }}                   as unknown_reason_key

),

with_fks as (

    select
        s.*,

        -- Foreign keys resolved against the conformed dimensions.
        {{ dbt_utils.generate_surrogate_key(['s.customer_id']) }}                            as _customer_key_natural,
        {{ dbt_utils.generate_surrogate_key(['s.zip_code']) }}                               as _geography_key_natural,
        s.service_profile_key                                                                as _service_profile_key_natural,

        -- Churn-reason mapping:
        --   churned      + real pair -> real key
        --   churned      + null pair -> 'Unknown' member
        --   not churned              -> 'Not Applicable' member
        case
            when s.is_churned = true
             and s.churn_category is null and s.churn_reason is null then u.unknown_reason_key
            when s.is_churned <> true                                 then u.not_applicable_reason_key
            else {{ dbt_utils.generate_surrogate_key(['s.churn_category', 's.churn_reason']) }}
        end                                                                                  as churn_reason_key,

        u.unknown_customer_key,
        u.unknown_geography_key,
        u.unknown_service_profile_key

    from source_360 s
    cross join unknown_keys u

),

lookup as (

    select
        w.*,
        dc.customer_key,
        dg.geography_key,
        dsp.service_profile_key                             as dim_service_profile_key
    from with_fks w
    left join {{ ref('dim_customer') }}         dc  on dc.customer_key         = w._customer_key_natural
    left join {{ ref('dim_geography') }}        dg  on dg.geography_key        = w._geography_key_natural
    left join {{ ref('dim_service_profile') }}  dsp on dsp.service_profile_key = w._service_profile_key_natural

),

final as (

    select
        -- Surrogate business key of the fact
        {{ dbt_utils.generate_surrogate_key(['customer_id', 'snapshot_month']) }} as customer_monthly_snapshot_key,

        -- Foreign keys (Unknown-member handling ensures none are null).
        -- We also expose the pre-coalesce natural key to keep observability.
        coalesce(customer_key,           unknown_customer_key)         as customer_key,
        coalesce(geography_key,          unknown_geography_key)        as geography_key,
        coalesce(dim_service_profile_key, unknown_service_profile_key) as service_profile_key,
        churn_reason_key,
        cast(date_format(snapshot_month, 'yyyyMMdd') as int)           as date_key,

        (customer_key           is not null)                            as is_customer_matched,
        (geography_key          is not null)                            as is_geography_matched,
        (dim_service_profile_key is not null)                           as is_service_profile_matched,

        -- Degenerate identifier (natural business key preserved)
        monthly_snapshot_id,
        customer_id,
        snapshot_month,

        -- Contextual attributes retained for convenience filtering
        tenure_months,

        -- Measures / additive flags
        monthly_charge,
        monthly_revenue,
        total_revenue,
        monthly_revenue_lost,

        customer_count,
        eligible_customer_count,
        churned_customer_count,
        stayed_customer_count,
        new_customer_count,

        -- Boolean flags (mutually exclusive)
        is_churned,
        is_stayed,
        is_new_customer,
        is_churn_eligible,

        -- Data quality
        data_quality_status,

        -- Audit
        source_updated_at,
        ingested_at,
        source_batch_id,
        ingestion_batch_id,
        current_timestamp() as dbt_loaded_at,
        '{{ invocation_id }}' as dbt_invocation_id

    from lookup

)

select * from final
