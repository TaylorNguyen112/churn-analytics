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
    Materialization    : Delta MERGE (unique_key='support_event_key').
    Watermark          : source_updated_at, 2-day lookback.

    Descriptive event attributes (issue_category, channel, priority,
    resolution_status) are kept on the fact intentionally.
*/

with source_enriched as (

    select * from {{ ref('int_support_event_enriched') }}

    {% if is_incremental() %}
    where coalesce(source_updated_at, cast('1900-01-01' as timestamp)) >= (
              select date_sub(
                  coalesce(max(source_updated_at), cast('1900-01-01' as timestamp)),
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

        coalesce(customer_key,            unknown_customer_key)         as customer_key,
        coalesce(geography_key,           unknown_geography_key)        as geography_key,
        coalesce(dim_service_profile_key, unknown_service_profile_key)  as service_profile_key,
        cast(date_format(event_date, 'yyyyMMdd') as int)                as date_key,

        (customer_key             is not null)                          as is_customer_matched,
        (geography_key            is not null)                          as is_geography_matched,
        (dim_service_profile_key  is not null)                          as is_service_profile_matched,
        is_customer_snapshot_matched,

        support_event_id,
        customer_id,

        event_timestamp,
        event_date,
        event_month,
        issue_category,
        channel,
        priority,
        resolution_status,

        customer_status_at_event_month,
        contract_type_at_event_month,
        internet_type_at_event_month,

        1                                                               as event_count,
        resolution_hours,
        satisfaction_score,
        is_resolved,
        is_escalated,
        is_resolution_hours_valid,
        is_satisfaction_score_valid,

        source_updated_at,
        source_batch_id,
        source_system,

        etl_source_system,
        {{ audit_columns() }}

    from lookup

)

select * from final
