/*
    dim_service_profile
    -------------------
    Grain          : one row per unique service configuration + Unknown.
    Source         : int_customer_service_profile (DISTINCT).
    Surrogate key  : service_profile_key (already computed in the
                     intermediate via the same generate_surrogate_key).
*/

with base as (

    select distinct
        service_profile_key,
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
        service_count,
        has_any_streaming_service,
        has_streaming_bundle,
        has_security_bundle,
        etl_source_system
    from {{ ref('int_customer_service_profile') }}

),

real_profiles as (

    select
        service_profile_key,
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
        service_count,
        has_any_streaming_service,
        has_streaming_bundle,
        has_security_bundle,
        false                                                 as is_unknown_member,
        etl_source_system,
        {{ audit_columns() }}
    from base

),

unknown_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as service_profile_key,
        cast('Unknown' as string)                             as offer,
        cast('Unknown' as string)                             as contract_type,
        cast('Unknown' as string)                             as internet_type,
        cast(null as boolean)                                 as has_phone_service,
        cast(null as boolean)                                 as has_multiple_lines,
        cast(null as boolean)                                 as has_internet_service,
        cast(null as boolean)                                 as has_online_security,
        cast(null as boolean)                                 as has_online_backup,
        cast(null as boolean)                                 as has_device_protection,
        cast(null as boolean)                                 as has_premium_tech_support,
        cast(null as boolean)                                 as has_streaming_tv,
        cast(null as boolean)                                 as has_streaming_movies,
        cast(null as boolean)                                 as has_streaming_music,
        cast(null as boolean)                                 as has_unlimited_data,
        cast(null as int)                                     as service_count,
        cast(null as boolean)                                 as has_any_streaming_service,
        cast(null as boolean)                                 as has_streaming_bundle,
        cast(null as boolean)                                 as has_security_bundle,
        true                                                  as is_unknown_member,
        cast(null as string)                                  as etl_source_system,
        {{ audit_columns() }}

)

select * from real_profiles
union all
select * from unknown_member
