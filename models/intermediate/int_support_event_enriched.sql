/*
    int_support_event_enriched
    --------------------------
    Grain      : one row per support_event_id (post-enrichment).
    Sources    : stg_customer_support_events   (spine)
                 int_customer_monthly_360      (historical customer context
                     joined on customer_id + event month = snapshot_month)

    Historical accuracy:
      - Every enrichment attribute is sourced from the customer's
        snapshot for the EVENT MONTH (not the current churn state).
      - When no matching monthly snapshot exists, snapshot-derived
        attributes are left NULL and `is_customer_snapshot_matched`
        exposes the mismatch. The event row itself is NEVER dropped.
      - The join is guaranteed one-to-one at the source grain because
        both sides are unique on their respective keys and the join
        predicates are business keys, not descriptive fields. Profiling
        showed 11,114 / 11,114 events match a monthly snapshot on the
        current dataset.
*/

with events as (

    select * from {{ ref('stg_customer_support_events') }}

),

customer_context as (

    select
        customer_id,
        snapshot_month,
        customer_status               as customer_status_at_event_month,
        contract_type                 as contract_type_at_event_month,
        internet_type                 as internet_type_at_event_month,
        zip_code,
        city,
        latitude,
        longitude,
        population,
        is_population_valid,
        service_profile_key
    from {{ ref('int_customer_monthly_360') }}

),

joined as (

    select
        e.support_event_id,
        e.customer_id,

        e.event_timestamp,
        cast(e.event_timestamp as date)                  as event_date,
        cast(date_trunc('month', e.event_timestamp) as date) as event_month,

        e.issue_category,
        e.channel,
        e.priority,
        e.resolution_status,

        e.resolution_hours,
        e.satisfaction_score,

        e.is_resolved,
        e.is_escalated,
        e.is_resolution_hours_valid,
        e.is_satisfaction_score_valid,

        cc.customer_status_at_event_month,
        cc.contract_type_at_event_month,
        cc.internet_type_at_event_month,
        cc.service_profile_key,

        cc.zip_code,
        cc.city,
        cc.latitude,
        cc.longitude,
        cc.population,
        cc.is_population_valid,

        (cc.customer_id is not null)                     as is_customer_snapshot_matched,

        e.source_updated_at,
        e.source_batch_id,
        e.source_system,
        e.etl_ingested_at                                as ingested_at,
        e.etl_run_id                                     as ingestion_batch_id,
        e.etl_source_file                                as source_file

    from events e
    left join customer_context cc
      on cc.customer_id    = e.customer_id
     and cc.snapshot_month = cast(date_trunc('month', e.event_timestamp) as date)

)

select * from joined
