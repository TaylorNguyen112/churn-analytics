/*
    dim_date
    --------
    Grain          : one row per calendar_date.
    Range          : 2024-01-01 through 2026-12-31 inclusive.
                     Chosen to comfortably cover:
                       - monthly snapshot range: 2025-01-01 .. 2025-12-01
                       - support event range:    2025-01-01 .. 2025-12-31
                     with a one-year buffer on either side to accommodate
                     new loads without immediate schema changes.
    date_key       : integer YYYYMMDD (e.g. 20250115).
    Materialization: table (small, ~1,096 rows).
*/

with spine as (

    {{ dbt_utils.date_spine(
        datepart='day',
        start_date="cast('2024-01-01' as date)",
        end_date="cast('2027-01-01' as date)"
    ) }}

),

renamed as (

    select cast(date_day as date) as calendar_date from spine

),

final as (

    select
        cast(date_format(calendar_date, 'yyyyMMdd') as int) as date_key,
        calendar_date,

        day(calendar_date)                                  as day_of_month,
        date_format(calendar_date, 'EEEE')                  as day_name,
        dayofweek(calendar_date)                            as day_of_week,     -- 1=Sunday .. 7=Saturday
        weekofyear(calendar_date)                           as week_of_year,

        month(calendar_date)                                as month_number,
        date_format(calendar_date, 'MMMM')                  as month_name,

        quarter(calendar_date)                              as quarter_number,
        concat('Q', cast(quarter(calendar_date) as string)) as quarter_name,

        year(calendar_date)                                 as year_number,
        date_format(calendar_date, 'yyyy-MM')               as year_month,
        concat(
            cast(year(calendar_date) as string),
            '-Q',
            cast(quarter(calendar_date) as string)
        )                                                   as year_quarter,

        trunc(calendar_date, 'MM')                          as month_start_date,
        last_day(calendar_date)                             as month_end_date,

        (calendar_date = trunc(calendar_date, 'MM'))        as is_month_start,
        (calendar_date = last_day(calendar_date))           as is_month_end,
        (dayofweek(calendar_date) in (1, 7))                as is_weekend,

        current_timestamp()                                 as dbt_loaded_at

    from renamed

)

select * from final
