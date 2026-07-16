/*
    Business rule (derived from Bronze profiling):

        resolution_status = 'Pending'
            -> resolution_hours   MUST be NULL
            -> satisfaction_score MUST be NULL

        resolution_status IN ('Resolved', 'Escalated', 'Closed - Unresolved')
            -> resolution_hours   MUST be NOT NULL
            -> satisfaction_score MUST be NOT NULL

    Rationale:
        Source profiling confirmed this pattern with 100% consistency
        across all 11,114 events:
            Pending             ->    0 non-null hours,    0 non-null scores
            Resolved / Escalated / Closed - Unresolved
                                -> 100% non-null hours, 100% non-null scores

        NOTE: `Closed - Unresolved` is NOT the same as `Pending`. It is a
        terminal status where the customer effectively closes the case
        without resolution, and the source still records the hours spent
        working the case plus a satisfaction score.

    Severity: error.
    Returns: rows that VIOLATE either half of the rule.
*/

select
    support_event_id,
    resolution_status,
    resolution_hours,
    satisfaction_score
from {{ ref('stg_customer_support_events') }}
where
    (
        resolution_status = 'Pending'
        and (resolution_hours is not null or satisfaction_score is not null)
    )
    or
    (
        resolution_status in ('Resolved', 'Escalated', 'Closed - Unresolved')
        and (resolution_hours is null or satisfaction_score is null)
    )
