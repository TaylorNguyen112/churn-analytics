/*
    Business rule:
        In int_customer_monthly_360 the additive count columns
        (customer_count, eligible_customer_count, churned_customer_count)
        and the boolean status flags must be internally consistent.

    Fails when:
        - customer_count != 1
        - churned_customer_count != (1 when is_churned else 0)
        - eligible_customer_count != (1 when is_churn_eligible else 0)
        - a customer is simultaneously in more than one status category
          (Churned + Stayed, Churned + Joined, or Stayed + Joined)
        - monthly_revenue_lost != monthly_charge when the customer is
          churned with a non-negative monthly_charge, else != 0

    Severity: error.
*/

with rows_ as (
    select * from {{ ref('int_customer_monthly_360') }}
),

violations as (
    select *
    from rows_
    where
        customer_count <> 1
        or churned_customer_count  <> case when is_churned         = true then 1 else 0 end
        or eligible_customer_count <> case when is_churn_eligible  = true then 1 else 0 end
        or (is_churned = true and is_stayed = true)
        or (is_churned = true and is_new_customer = true)
        or (is_stayed  = true and is_new_customer = true)
        or monthly_revenue_lost <> case
                                     when is_churned = true
                                      and monthly_charge is not null
                                      and monthly_charge >= 0
                                     then monthly_charge
                                     else cast(0 as decimal(18,2))
                                   end
)

select * from violations
