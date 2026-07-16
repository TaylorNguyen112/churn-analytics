/*
    Business rule:
        int_zipcode_geography must be strictly one row per zip_code with
        a single (city, latitude, longitude) tuple per ZIP.

    Fails when a ZIP has multiple geography attribute combinations.
    Severity: error.
*/

select
    zip_code,
    count(*) as n_rows,
    count(distinct city)      as distinct_cities,
    count(distinct latitude)  as distinct_latitudes,
    count(distinct longitude) as distinct_longitudes
from {{ ref('int_zipcode_geography') }}
group by zip_code
having count(*) > 1
    or count(distinct city)      > 1
    or count(distinct latitude)  > 1
    or count(distinct longitude) > 1
