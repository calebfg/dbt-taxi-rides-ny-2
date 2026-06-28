# NYC TLC Analytics Engineering Pipeline

A production-grade analytics engineering project that transforms 115M+ raw NYC taxi trip records into a tested, documented, and business-ready analytical layer using dbt and Google BigQuery.

---

## Overview

This project implements the transformation layer of a modern data platform for New York City taxi operations. Raw trip data from the NYC Taxi and Limousine Commission (TLC) is ingested into BigQuery via an orchestrated ELT pipeline, then transformed through a multi-layer dbt project into clean, tested, and documented analytical models ready for business intelligence consumption.

The pipeline processes over **115 million trips** across green and yellow taxi services for 2019–2020, enriches them with geospatial zone data, and delivers pre-aggregated revenue metrics that power operational dashboards.

---

## Architecture

```
NYC TLC Source Data
        │
        ▼
Kestra Orchestration (ELT Pipeline)
  ├── Download monthly CSV files from source
  ├── Upload to Google Cloud Storage
  └── Load into BigQuery (nytaxi dataset)
        │
        ▼
BigQuery Raw Layer (nytaxi dataset)
  ├── green_tripdata     (~7.8M rows, 2019-2020)
  └── yellow_tripdata    (~109M rows, 2019-2020)
        │
        ▼
dbt Transformation Layer
  ├── Staging (views)
  │     ├── stg_green_tripdata
  │     └── stg_yellow_tripdata
  ├── Core (tables)
  │     ├── dim_zones
  │     ├── fact_trips         (115M+ rows)
  │     └── dm_monthly_zone_revenue  (12,498 rows)
        │
        ▼
BigQuery Analytics Layer (production dataset)
        │
        ▼
BI Tools / Dashboards
```

---

## Data Pipeline

### Ingestion Layer (Upstream)

Raw data is loaded into BigQuery by an orchestrated Kestra pipeline. The pipeline:

- Downloads monthly CSV files from the NYC TLC data repository
- Stages files in Google Cloud Storage
- Creates external tables pointing at GCS files
- Loads data into monthly staging tables via `CREATE TABLE AS SELECT`
- Merges monthly data into unified `green_tripdata` and `yellow_tripdata` tables using MD5-based deduplication to ensure idempotency

The ingestion layer is completely separate from the transformation layer. dbt reads from BigQuery raw tables and never interacts with the ingestion pipeline directly.

### Transformation Layer (This Repository)

The dbt project implements a three-layer transformation architecture:

**Staging** → **Core** → **Data Mart**

Each layer has a specific purpose and audience. Raw data never reaches end users — only the final mart layer is exposed to BI tools.

---

## Project Structure

```
dbt-taxi-rides-ny-2/
├── dbt_project.yml              # Project configuration and materialization defaults
├── packages.yml                 # Package dependencies (dbt_utils 1.3.0)
├── models/
│   ├── staging/
│   │   ├── schema.yml           # Source definitions, model tests, column documentation
│   │   ├── stg_green_tripdata.sql
│   │   └── stg_yellow_tripdata.sql
│   └── core/
│       ├── schema.yml           # Core model tests and documentation
│       ├── dim_zones.sql
│       ├── fact_trips.sql
│       └── dm_monthly_zone_revenue.sql
├── macros/
│   └── get_payment_type_description.sql
└── seeds/
    └── taxi_zone_lookup.csv
```

---

## Models

### Staging Layer

Staging models sit directly on top of raw source tables. Their only job is cosmetic cleanup — no business logic, no joins, no aggregations. Each staging model is a one-to-one representation of a source table with:

- Consistent column naming (snake_case throughout)
- Explicit data type casting
- A generated surrogate key for use as a primary key downstream
- Human-readable payment type labels via macro

Staging models are materialized as **views** — they store no data and always reflect the latest source, making them cheap to maintain and always fresh.

#### `stg_green_tripdata`

Cleans and standardizes NYC green taxi trip records.

| Transformation | Detail |
|---|---|
| Surrogate key | MD5 hash of `vendorid + lpep_pickup_datetime + pulocationid + dolocationid` |
| Column renames | `lpep_pickup_datetime` → `pickup_datetime`, `PULocationID` → `pickup_locationid` |
| Type casting | All columns explicitly cast to correct types |
| Payment labels | Integer codes converted to descriptions via `get_payment_type_description` macro |
| Source | `nytaxi.green_tripdata` |

#### `stg_yellow_tripdata`

Cleans and standardizes NYC yellow taxi trip records. Structurally identical to the green model with two differences:

- Timestamp columns use `tpep_` prefix instead of `lpep_`
- `trip_type` and `ehail_fee` columns are set to `NULL` — these fields do not exist for yellow taxis by law (yellow taxis can only be street-hailed and do not support e-hail fees)

This design decision ensures both staging models have identical schemas, enabling a clean `UNION ALL` in `fact_trips` without column mismatches.

---

### Core Layer

Core models implement business logic — joins, unions, and aggregations. They are materialized as **tables** because they are queried repeatedly by analysts and BI tools and must perform at scale.

#### `dim_zones`

Dimension table mapping 265 NYC taxi zone location IDs to human-readable attributes.

Built from the `taxi_zone_lookup` seed file. Applies one business rule: renames `service_zone = 'Boro Zone'` to `'Green Zone'` to accurately reflect that these areas are exclusively served by green taxis.

| Column | Description |
|---|---|
| `locationid` | Primary key. Unique identifier for each taxi zone |
| `borough` | NYC borough (Manhattan, Queens, Brooklyn, Bronx, Staten Island) |
| `zone` | Human-readable zone name (e.g. JFK Airport, Times Square) |
| `service_zone` | Type of service zone (Yellow Zone, Green Zone, Airports, EWR) |

#### `fact_trips`

Central fact table combining all green and yellow taxi trips. One row per trip.

**Design decisions:**

- **UNION ALL over separate tables:** Green and yellow trips are combined into one table with a `service_type` column. This eliminates the need for analysts to write manual unions in every query and enables simple `GROUP BY service_type` analysis.

- **Inner join with dim_zones:** Trips are joined with `dim_zones` twice — once for pickup zone, once for dropoff zone. An inner join is used deliberately: trips with unrecognized location IDs are excluded to ensure every row in the fact table has valid, enriched zone information. Approximately 1.5M trips (~1.3%) are excluded for this reason.

- **Table materialization:** With 115M+ rows, materializing as a table ensures consistent query performance. A view would re-scan the full dataset on every dashboard load.

| Column | Description |
|---|---|
| `tripid` | Primary key. Surrogate key generated from trip attributes |
| `service_type` | Green or Yellow |
| `pickup_locationid` | Raw location ID where trip started |
| `pickup_borough` | Borough name for pickup location |
| `pickup_zone` | Zone name for pickup location |
| `dropoff_locationid` | Raw location ID where trip ended |
| `dropoff_borough` | Borough name for dropoff location |
| `dropoff_zone` | Zone name for dropoff location |
| `pickup_datetime` | Timestamp when meter engaged |
| `dropoff_datetime` | Timestamp when meter disengaged |
| `passenger_count` | Number of passengers |
| `trip_distance` | Trip distance in miles |
| `trip_type` | Street hail (1) or dispatch (2). NULL for yellow taxis |
| `fare_amount` | Time-and-distance fare |
| `tip_amount` | Tip amount (credit card tips only) |
| `total_amount` | Total charged to passenger |
| `payment_type_description` | Human-readable payment method |
| `ehail_fee` | E-hail fee. NULL for yellow taxis |

#### `dm_monthly_zone_revenue`

Pre-aggregated data mart for revenue analysis by service type, pickup zone, and month.

**Why this exists:** Querying `fact_trips` for monthly revenue by zone requires scanning 115M rows on every dashboard load. This mart pre-computes those aggregations into 12,498 rows — reducing dashboard query time from seconds to milliseconds.

Groups `fact_trips` by `service_type`, `pickup_zone`, and month. Calculates:
- Revenue metrics: fare, tips, tolls, surcharges, total amount
- Volume metrics: trip count, average passenger count, average trip distance

---

## Macros

### `get_payment_type_description(payment_type)`

Converts raw integer payment type codes to human-readable labels.

| Code | Description |
|---|---|
| 1 | Credit card |
| 2 | Cash |
| 3 | No charge |
| 4 | Dispute |
| 5 | Unknown |
| 6 | Voided trip |

**Design rationale:** Both `stg_green_tripdata` and `stg_yellow_tripdata` require this same conversion. Rather than duplicating the CASE statement, it is encapsulated in a macro — consistent with the DRY (Don't Repeat Yourself) principle. A single update to the macro propagates to all models that reference it.

---

## Seeds

### `taxi_zone_lookup.csv`

Static reference file mapping 265 NYC TLC location IDs to zone names, boroughs, and service zone classifications.

Loaded into BigQuery via `dbt seed`. Chosen as a seed (rather than a pipeline-loaded table) because:
- 265 rows — too small to justify a full ingestion pipeline
- Rarely changes — NYC taxi zones are stable over time
- Belongs with the analytics codebase — it is reference data that the transformation layer owns

---

## Data Quality Tests

Tests are defined in `schema.yml` files alongside each layer's models. All tests use `severity: warn` — failures are surfaced without stopping the pipeline, allowing known data quality issues to be monitored without blocking production runs.

| Test | Column | Model | Purpose |
|---|---|---|---|
| `unique` | `tripid` | stg_green_tripdata, stg_yellow_tripdata, fact_trips | Detect duplicate trips |
| `not_null` | `tripid` | stg_green_tripdata, stg_yellow_tripdata, fact_trips | Ensure surrogate key generation succeeded |
| `relationships` | `pickup_locationid` | stg_green_tripdata, stg_yellow_tripdata | Validate all pickup locations exist in zone reference |
| `relationships` | `dropoff_locationid` | stg_green_tripdata, stg_yellow_tripdata | Validate all dropoff locations exist in zone reference |
| `accepted_values` | `payment_type_description` | stg_green_tripdata, stg_yellow_tripdata | Flag unexpected payment type codes |
| `unique` | `locationid` | dim_zones | Ensure dimension table has no duplicate keys |
| `not_null` | `locationid` | dim_zones | Ensure dimension table primary key is never null |

### Known Data Quality Issues

| Issue | Affected Model | Impact | Resolution |
|---|---|---|---|
| Duplicate `tripid` values | stg_green_tripdata, stg_yellow_tripdata, fact_trips | Some trips have identical key field combinations in source | Monitored via warn-severity test. Source data issue — not caused by transformation logic |
| Payment types outside 1-6 | stg_green_tripdata, stg_yellow_tripdata | Historical records with deprecated payment codes | Macro returns 'EMPTY' for unknown codes. Monitored via accepted_values test |
| ~12% null `vendorid` | stg_green_tripdata | Some vendors did not transmit all fields | Documented. Included in surrogate key hash with empty string coalescing |

---

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `is_test_run` | `true` | Controls development query limits |
| `payment_type_values` | `[1, 2, 3, 4, 5, 6]` | Valid payment type codes referenced in accepted_values tests |

---

## Packages

| Package | Version | Usage |
|---|---|---|
| `dbt-labs/dbt_utils` | 1.3.0 | `generate_surrogate_key` macro for cross-platform MD5 hashing |

Install packages:
```bash
dbt deps
```

---

## Setup

### Prerequisites

- dbt Cloud account (free Developer plan)
- GCP project with BigQuery API enabled
- Service account with BigQuery Data Editor, Job User, and User roles
- Raw taxi data loaded into BigQuery `nytaxi` dataset (green and yellow, 2019-2020)

### Commands

```bash
# Install package dependencies
dbt deps

# Load seed reference data
dbt seed

# Run all models
dbt run --vars '{"is_test_run": false}'

# Run specific model and all upstream dependencies
dbt run --select +fact_trips --vars '{"is_test_run": false}'

# Run data quality tests
dbt test

# Build everything (seed + run + test in dependency order)
dbt build --vars '{"is_test_run": false}'
```

---

## DAG

```
nytaxi.green_tripdata ──► stg_green_tripdata ──┐
                                                 ├──► fact_trips ──► dm_monthly_zone_revenue
nytaxi.yellow_tripdata ──► stg_yellow_tripdata ─┘        ▲
                                                          │
taxi_zone_lookup.csv ──► dim_zones ───────────────────────┘
```

dbt determines execution order automatically from `ref()` dependencies. Models are always run in the correct sequence.

---

## Technical Stack

| Component | Technology |
|---|---|
| Data Warehouse | Google BigQuery |
| Transformation | dbt Cloud (Fusion runtime) |
| Orchestration | Kestra |
| Cloud Storage | Google Cloud Storage |
| Version Control | GitHub |
| Infrastructure | Terraform (GCP provisioning) |

---

## Author

Kaleab Gebretsadike
GitHub: [calebfg](https://github.com/calebfg)
