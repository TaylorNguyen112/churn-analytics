/*
    int_zipcode_geography
    ---------------------
    Grain      : one row per zip_code.
    Sources    : stg_telecom_zipcode_population (population, 1,671 zips)
                 stg_telecom_customer_churn (city, latitude, longitude,
                     for 1,626 zips - subset of the population table).
    Approach   : LEFT JOIN population <- deduplicated geography agg from
                 the customer table. Profiling proved zip -> city and
                 zip -> (latitude, longitude) are strict 1:1 mappings in
                 the current data, so MIN() aggregation is deterministic
                 (all values in each group are identical).

    Fields not available in any source (documented gaps):
      - state, region
      A future enhancement can enrich these via a seed containing a
      ZIP -> state/region mapping.
*/

with population as (

    select * from {{ ref('stg_telecom_zipcode_population') }}

),

geography_agg as (

    -- Deduplicate customer-side geography attributes to one row per zip.
    -- Profiling confirmed exactly one distinct city / lat / long per zip.
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

        cast(null as string)             as state,   -- not available in source
        cast(null as string)             as region,  -- not available in source

        p.etl_ingested_at                as ingested_at,
        p.etl_run_id                     as ingestion_batch_id

    from population p
    left join geography_agg g on g.zip_code = p.zip_code

)

select * from final
