{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='customer_monthly_snapshot_key',
        on_schema_change='sync_all_columns',
        tags=['gold', 'fact']
    )
}}

/*
    fct_customer_monthly_snapshot
    -----------------------------
    Grain              : one row per (customer_id, snapshot_month).
    Source             : int_customer_monthly_360 (spine)
                       + dim_customer / dim_geography /
                         dim_service_profile / dim_churn_reason / dim_date.
    Materialization    : Delta MERGE (unique_key='customer_monthly_snapshot_key').

    Watermark          : source_updated_at, with 2-day lookback to absorb
                         late-arriving corrections. snapshot_month is NOT
                         a valid watermark because historical months can
                         receive retroactive updates.

    Unknown members    : Every FK is COALESCEd to the deterministic
                         Unknown surrogate hash so no FK is ever null.
*/

with source_360 as (

    select * from {{ ref('int_customer_monthly_360') }}

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
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_customer_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_geography_key,
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }}                                as unknown_service_profile_key,
        {{ dbt_utils.generate_surrogate_key(["'Not Applicable'", "'Not Applicable'"]) }}     as not_applicable_reason_key,
        {{ dbt_utils.generate_surrogate_key(["'Unknown'", "'Unknown'"]) }}                   as unknown_reason_key

),

with_fks as (

    select
        s.*,

        {{ dbt_utils.generate_surrogate_key(['s.customer_id']) }}                            as _customer_key_natural,
        {{ dbt_utils.generate_surrogate_key(['s.zip_code']) }}                               as _geography_key_natural,
        s.service_profile_key                                                                as _service_profile_key_natural,

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
        {{ dbt_utils.generate_surrogate_key(['customer_id', 'snapshot_month']) }} as customer_monthly_snapshot_key,

        coalesce(customer_key,           unknown_customer_key)         as customer_key,
        coalesce(geography_key,          unknown_geography_key)        as geography_key,
        coalesce(dim_service_profile_key, unknown_service_profile_key) as service_profile_key,
        churn_reason_key,
        cast(date_format(snapshot_month, 'yyyyMMdd') as int)           as date_key,

        (customer_key             is not null)                          as is_customer_matched,
        (geography_key            is not null)                          as is_geography_matched,
        (dim_service_profile_key  is not null)                          as is_service_profile_matched,

        monthly_snapshot_id,
        customer_id,
        snapshot_month,

        tenure_months,

        monthly_charge,
        monthly_revenue,
        total_revenue,
        monthly_revenue_lost,

        customer_count,
        eligible_customer_count,
        churned_customer_count,
        stayed_customer_count,
        new_customer_count,

        is_churned,
        is_stayed,
        is_new_customer,
        is_churn_eligible,

        data_quality_status,

        source_updated_at,
        source_batch_id,
        source_system,

        etl_source_system,
        {{ audit_columns() }}

    from lookup

)

select * from final
