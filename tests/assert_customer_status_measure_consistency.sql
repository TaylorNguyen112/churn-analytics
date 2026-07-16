/*
    Business rule:
        In fct_customer_monthly_snapshot every additive count column and
        every boolean flag must be internally consistent. Specifically:

          - customer_count = 1 for every row
          - churned_customer_count = case when is_churned then 1 else 0 end
          - eligible_customer_count = case when is_churn_eligible then 1 else 0 end
          - stayed_customer_count = case when is_stayed then 1 else 0 end
          - new_customer_count = case when is_new_customer then 1 else 0 end
          - a customer cannot be simultaneously Churned + Stayed,
            Churned + New, or Stayed + New
          - monthly_revenue_lost = monthly_charge when churned and
            monthly_charge >= 0, else 0
          - is_resolved / is_escalated in the support fact agree with
            resolution_status (this fact-specific check is enforced on
            the support fact separately).

    Fails when any row violates any of the above. Severity: error.
*/

select *
from {{ ref('fct_customer_monthly_snapshot') }}
where
    customer_count           <> 1
 or churned_customer_count   <> case when is_churned        = true then 1 else 0 end
 or eligible_customer_count  <> case when is_churn_eligible = true then 1 else 0 end
 or stayed_customer_count    <> case when is_stayed         = true then 1 else 0 end
 or new_customer_count       <> case when is_new_customer   = true then 1 else 0 end
 or (is_churned = true and is_stayed        = true)
 or (is_churned = true and is_new_customer  = true)
 or (is_stayed  = true and is_new_customer  = true)
 or monthly_revenue_lost <> case
                              when is_churned = true
                               and monthly_charge is not null
                               and monthly_charge >= 0
                              then monthly_charge
                              else cast(0 as decimal(18,2))
                            end
