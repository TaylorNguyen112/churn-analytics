{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='support_event_key',
        on_schema_change='sync_all_columns',
        tags=['gold', 'core', 'fact']
    )
}}

/*
    fct_support_event
    -----------------
    Grain              : one row per support_event_id.
    Source             : int_support_event_enriched.
    Materialization    : Delta MERGE with unique_key = support_event_key.

    Descriptive event attributes (issue_category, channel, priority,
    resolution_status) are LOW-cardinality event characteristics and are
    intentionally kept on the fact rather than promoted to their own
    dimensions. Promoting each to a dim would create narrow dimensions
    with limited descriptive power (Kimball anti-pattern).

    Watermark and lookback:
      Same pattern as fct_customer_monthly_snapshot - filter by
      greatest(source_updated_at, ingested_at) with a 2-day lookback
      to absorb late-arriving updates.

    Optional dim_service_profile FK:
      Populated only when the event has a matched customer snapshot
      (is_customer_snapshot_matched = true). Otherwise resolves to the
      Unknown service_profile_key.
*/

with source_enriched as (

    select * from {{ ref('int_support_event_enriched') }}

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

unknown_keys as (

    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as unknown_customer_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as unknown_geography_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as unknown_service_profile_key

),

with_fks as (

    select
        e.*,
        {{ dbt_utils.generate_surrogate_key(['e.customer_id']) }} as _customer_key_natural,
        {{ dbt_utils.generate_surrogate_key(['e.zip_code']) }}    as _geography_key_natural,
        u.unknown_customer_key,
        u.unknown_geography_key,
        u.unknown_service_profile_key
    from source_enriched e
    cross join unknown_keys u

),

lookup as (

    select
        w.*,
        dc.customer_key,
        dg.geography_key,
        dsp.service_profile_key as dim_service_profile_key
    from with_fks w
    left join {{ ref('dim_customer') }}   dc on dc.customer_key   = w._customer_key_natural
    left join {{ ref('dim_geography') }}  dg on dg.geography_key  = w._geography_key_natural
    left join {{ ref('dim_service_profile') }} dsp on dsp.service_profile_key = w.service_profile_key

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['support_event_id']) }} as support_event_key,

        -- Foreign keys with Unknown-member fallback
        coalesce(customer_key,            unknown_customer_key)         as customer_key,
        coalesce(geography_key,           unknown_geography_key)        as geography_key,
        coalesce(dim_service_profile_key, unknown_service_profile_key)  as service_profile_key,
        cast(date_format(event_date, 'yyyyMMdd') as int)                as date_key,

        (customer_key             is not null)                          as is_customer_matched,
        (geography_key            is not null)                          as is_geography_matched,
        (dim_service_profile_key  is not null)                          as is_service_profile_matched,
        is_customer_snapshot_matched,

        -- Degenerate identifier
        support_event_id,
        customer_id,

        -- Event descriptive attributes (kept on the fact intentionally)
        event_timestamp,
        event_date,
        event_month,
        issue_category,
        channel,
        priority,
        resolution_status,

        -- Historical customer context (may be null when unmatched)
        customer_status_at_event_month,
        contract_type_at_event_month,
        internet_type_at_event_month,

        -- Measures / flags
        1                                                               as event_count,
        resolution_hours,
        satisfaction_score,
        is_resolved,
        is_escalated,
        is_resolution_hours_valid,
        is_satisfaction_score_valid,

        -- Audit
        source_updated_at,
        ingested_at,
        source_batch_id,
        ingestion_batch_id,
        current_timestamp()                                             as dbt_loaded_at,
        '{{ invocation_id }}'                                           as dbt_invocation_id

    from lookup

)

select * from final
