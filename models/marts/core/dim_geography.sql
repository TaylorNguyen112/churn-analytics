/*
    dim_geography
    -------------
    Grain          : one row per zip_code.
    Source         : int_zipcode_geography.
    Surrogate key  : dbt_utils.generate_surrogate_key(['zip_code']).
    Unknown member : geography_key = hash('UNKNOWN'), zip_code = 'UNKNOWN'.

    Fields not available in the current source (populated as NULL):
      state, region. Enrich via a seed if a ZIP -> state/region reference
      becomes available.
*/

with base as (

    select
        zip_code,
        city,
        state,
        latitude,
        longitude,
        population,
        is_population_valid
    from {{ ref('int_zipcode_geography') }}

),

real_geography as (

    select
        {{ dbt_utils.generate_surrogate_key(['zip_code']) }} as geography_key,
        zip_code,
        city,
        state,
        cast(null as string)                as region,
        latitude,
        longitude,
        population,
        is_population_valid,
        false                               as is_unknown_member,
        current_timestamp()                 as dbt_loaded_at
    from base

),

unknown_member as (

    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as geography_key,
        cast('UNKNOWN' as string)                             as zip_code,
        cast('Unknown' as string)                             as city,
        cast(null as string)                                  as state,
        cast(null as string)                                  as region,
        cast(null as double)                                  as latitude,
        cast(null as double)                                  as longitude,
        cast(null as bigint)                                  as population,
        cast(null as boolean)                                 as is_population_valid,
        true                                                  as is_unknown_member,
        current_timestamp()                                   as dbt_loaded_at

)

select * from real_geography
union all
select * from unknown_member
