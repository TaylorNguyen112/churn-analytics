{{
    config(
        materialized='view',
        tags=['silver', 'staging']
    )
}}

/*
    stg_telecom_zipcode_population
    ------------------------------
    Grain           : one row per zip_code.
    Source          : {{ source('bronze', 'telecom_zipcode_population') }}
    Business key    : zip_code (5-char string)
    Dedup ordering  : Bronze `etl_ingested_at`, `etl_file_row_number`
                      used INTERNALLY only; not projected downstream.
*/

with source as (

    select * from {{ source('bronze', 'telecom_zipcode_population') }}

),

renamed as (

    select
        lpad(cast(`Zip Code` as string), 5, '0')  as zip_code,
        try_cast(Population as bigint)            as population,

        etl_ingested_at                           as _dedup_ingested_at,
        etl_file_row_number                       as _dedup_row_number,
        etl_source_system                         as etl_source_system

    from source

),

deduplicated as (

    select
        r.*,
        row_number() over (
            partition by zip_code
            order by
                _dedup_ingested_at desc,
                _dedup_row_number  desc
        ) as _row_num
    from renamed r

),

final as (

    select
        zip_code,
        population,

        case
            when population is null then null
            when population > 0     then true
            else false
        end as is_population_valid,

        etl_source_system,
        {{ audit_columns() }}

    from deduplicated
    where _row_num = 1

)

select * from final
