/*
    dim_date
    --------
    Grain          : one row per calendar_date.
    Range          : 2024-01-01 through 2026-12-31 inclusive.
    date_key       : integer YYYYMMDD.
    Materialization: table (~1,096 rows).

    dim_date has no upstream data source, so etl_source_system is set to
    the sentinel 'DBT' to distinguish these rows from source-derived
    rows in downstream monitoring.
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
        dayofweek(calendar_date)                            as day_of_week,
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

        cast('DBT' as string)                               as etl_source_system,
        {{ audit_columns() }}

    from renamed

)

select * from final
