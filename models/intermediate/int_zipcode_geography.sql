/*
    int_zipcode_geography
    ---------------------
    Grain      : one row per zip_code.
    Sources    : stg_telecom_zipcode_population (population, 1,671 zips)
                 stg_telecom_customer_churn (city / lat / long for
                     1,626 zips - subset of the population table).
    Approach   : LEFT JOIN population <- deduplicated geography
                 aggregate from the customer table. Profiling proved
                 zip -> city and zip -> (latitude, longitude) are strict
                 1:1 mappings, so MIN() aggregation is deterministic.
    Gaps       : state, region unavailable in any source.
*/

with population as (

    select * from {{ ref('stg_telecom_zipcode_population') }}

),

geography_agg as (

    select
        zip_code,
        min(city)      as city,
        min(latitude)  as latitude,
        min(longitude) as longitude
    from {{ ref('stg_telecom_customer_churn') }}
    where zip_code is not null
    group by zip_code

),

final as (

    select
        p.zip_code,
        g.city,
        g.latitude,
        g.longitude,
        p.population,
        p.is_population_valid,

        cast(null as string)             as state,
        cast(null as string)             as region,

        p.etl_source_system              as etl_source_system,
        {{ audit_columns() }}

    from population p
    left join geography_agg g on g.zip_code = p.zip_code

)

select * from final
