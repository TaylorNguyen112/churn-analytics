{{
    config(
        materialized='view',
        tags=['silver', 'staging']
    )
}}

/*
    stg_customer_support_events
    ---------------------------
    Grain           : one row per support_event_id (post-dedup).
    Source          : {{ source('bronze', 'customer_support_events') }}
    Business key    : support_event_id
    Dedup ordering  : source `updated_at DESC` (primary), Bronze
                      etl_ingested_at / etl_file_row_number as tiebreakers.
                      Bronze ETL columns are used INTERNALLY only.
    Data-quality
    findings        : Source profiling shows a strict pattern -
                      Pending events ALWAYS have NULL resolution_hours
                      and NULL satisfaction_score; all terminal statuses
                      (Resolved / Escalated / Closed - Unresolved) have
                      BOTH populated. Enforced in the singular test
                      `assert_support_resolution_consistency`.
*/

with source as (

    select * from {{ source('bronze', 'customer_support_events') }}

),

renamed as (

    select
        trim(support_event_id)                              as support_event_id,
        trim(customer_id)                                   as customer_id,

        try_cast(event_timestamp as timestamp)              as event_timestamp,

        nullif(trim(issue_category),    '')                 as issue_category,
        nullif(trim(channel),           '')                 as channel,
        nullif(trim(priority),          '')                 as priority,
        nullif(trim(resolution_status), '')                 as resolution_status,

        try_cast(resolution_hours   as decimal(18,2))       as resolution_hours,
        try_cast(satisfaction_score as int)                 as satisfaction_score,

        try_cast(updated_at as timestamp)                   as source_updated_at,
        nullif(trim(batch_id), '')                          as source_batch_id,
        nullif(trim(source_system), '')                     as source_system,

        etl_ingested_at                                     as _dedup_ingested_at,
        etl_file_row_number                                 as _dedup_row_number,
        etl_source_system                                   as etl_source_system

    from source

),

deduplicated as (

    select
        r.*,
        row_number() over (
            partition by support_event_id
            order by
                source_updated_at   desc,
                _dedup_ingested_at  desc,
                _dedup_row_number   desc
        ) as _row_num
    from renamed r

),

final as (

    select
        support_event_id,
        customer_id,

        event_timestamp,

        issue_category,
        channel,
        priority,
        resolution_status,

        resolution_hours,
        satisfaction_score,

        case
            when resolution_hours is null then true
            when resolution_hours >= 0    then true
            else false
        end as is_resolution_hours_valid,

        case
            when satisfaction_score is null then true
            when satisfaction_score between 1 and 5 then true
            else false
        end as is_satisfaction_score_valid,

        case
            when resolution_status is null      then null
            when resolution_status = 'Resolved' then true
            else false
        end as is_resolved,

        case
            when resolution_status is null       then null
            when resolution_status = 'Escalated' then true
            else false
        end as is_escalated,

        source_updated_at,
        source_batch_id,
        source_system,

        etl_source_system,
        {{ audit_columns() }}

    from deduplicated
    where _row_num = 1

)

select * from final
