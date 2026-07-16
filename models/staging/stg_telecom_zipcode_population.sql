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
    Dedup ordering  : etl_ingested_at DESC, etl_file_row_number DESC
                      (No source updated_at exists on this table.)
    Data-quality
    findings        : No duplicates, no null populations, no non-positive
                      populations in current data. `is_population_valid` is
                      retained for future ingests where quality may vary.
*/

with source as (

    select * from {{ source('bronze', 'telecom_zipcode_population') }}

),

renamed as (

    select
        lpad(cast(`Zip Code` as string), 5, '0')  as zip_code,
        try_cast(Population as bigint)            as population,

        etl_ingested_at                           as etl_ingested_at,
        etl_source_system                         as etl_source_system,
        etl_run_id                                as etl_run_id,
        etl_job_id                                as etl_job_id,
        etl_task_name                             as etl_task_name,
        etl_source_file                           as etl_source_file,
        etl_file_row_number                       as etl_file_row_number
    from source

),

deduplicated as (

    select
        r.*,
        row_number() over (
            partition by zip_code
            order by
                etl_ingested_at    desc,
                etl_file_row_number desc
        ) as _row_num
    from renamed r

),

final as (

    select
        zip_code,
        population,

        case
            when population is null then null
            when population > 0 then true
            else false
        end as is_population_valid,

        etl_ingested_at,
        etl_source_system,
        etl_run_id,
        etl_job_id,
        etl_task_name,
        etl_source_file,
        etl_file_row_number

    from deduplicated
    where _row_num = 1

)

select * from final
