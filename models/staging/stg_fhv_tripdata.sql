{{ config(materialized='view') }}

select
    dispatching_base_num,
    cast(pickup_datetime as timestamp) as pickup_datetime,
    cast(dropoff_datetime as timestamp) as dropoff_datetime,
    cast(PULocationID as integer) as pickup_location_id,
    cast(DOLocationID as integer) as dropoff_location_id,
    SR_Flag as sr_flag,
    Affiliated_base_number as affiliated_base_number

from {{ source('staging_source', 'fhv_tripdata') }}

where dispatching_base_num is not null