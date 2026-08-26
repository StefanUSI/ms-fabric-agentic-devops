# Reversal plan - GitHub Issue #2

Generated 2026-08-26T08:56:07Z BEFORE any write.

**No step below is executed by an agent.** Cleanup is a human action
(CLAUDE.md rule 5 and the compensating controls in
docs/environment-and-constraints.md). This file exists so that the
decision to reverse is a decision, not an improvisation.

## What this ticket creates

Every item is NEW and prefixed `issue2_`. Nothing pre-existing is
modified, so reversal is deletion of newly created items rather than
restoration of prior definitions.

| # | Item | Type | Reversal |
|---|---|---|---|
| 1 | `issue2_retail_lakehouse` | Lakehouse | Delete the item (human, via the Fabric portal) |
| 2 | `issue2_00_generate_source` | Notebook | Delete the item (human, via the Fabric portal) |
| 3 | `issue2_10_bronze_ingest` | Notebook | Delete the item (human, via the Fabric portal) |
| 4 | `issue2_20_silver_transform` | Notebook | Delete the item (human, via the Fabric portal) |
| 5 | `issue2_30_gold_build` | Notebook | Delete the item (human, via the Fabric portal) |
| 6 | `issue2_90_validate` | Notebook | Delete the item (human, via the Fabric portal) |
| 7 | `issue2_retail_medallion_pipeline` | DataPipeline | Delete the item (human, via the Fabric portal) |

## Order

Delete the pipeline first, then the notebooks, then the Lakehouse last.
The Lakehouse holds every table and file, so deleting it first would
strand the other items against a target that no longer exists and
discard the evidence files before they could be retrieved.

## Data

All data written by this ticket lives inside `issue2_retail_lakehouse`,
which this ticket creates. Deleting that Lakehouse removes every table
and file listed below in one action. No path outside it was written,
so no other data needs to be considered.

- `issue2_retail_lakehouse/Files/issue2/landing/**` (write)
- `issue2_retail_lakehouse/Files/issue2/evidence/**` (write)
- `issue2_retail_lakehouse/Tables/issue2_bronze_sales` (write)
- `issue2_retail_lakehouse/Tables/issue2_bronze_stores` (write)
- `issue2_retail_lakehouse/Tables/issue2_bronze_products` (write)
- `issue2_retail_lakehouse/Tables/issue2_bronze_customers` (write)
- `issue2_retail_lakehouse/Tables/issue2_silver_sales` (write)
- `issue2_retail_lakehouse/Tables/issue2_silver_quarantine_sales` (write)
- `issue2_retail_lakehouse/Tables/issue2_silver_dim_store` (write)
- `issue2_retail_lakehouse/Tables/issue2_silver_dim_product` (write)
- `issue2_retail_lakehouse/Tables/issue2_silver_dim_customer` (write)
- `issue2_retail_lakehouse/Tables/issue2_gold_daily_store_sales` (write)
- `issue2_retail_lakehouse/Tables/issue2_gold_product_performance` (write)
- `issue2_retail_lakehouse/Tables/issue2_gold_customer_segment_kpi` (write)

## Auto-generated companions

The SQL analytics endpoint and the default semantic model are created
by the platform alongside the Lakehouse. They are removed with it and
need no separate step.

## Snapshots

None, and none required: no existing item is modified. Were that to
change, `Publish-FabricItemDefinition` refuses to update an item
without a snapshot, so this section cannot silently become wrong.

## Repository

1. Close the pull request without merging.
2. Delete the feature branch (human).

## Irreversible steps

None. Every Fabric object is newly created by this ticket, and every
repository change is confined to an unmerged feature branch.

**Data-loss risk: none.** All data is synthetic, deterministic and
regenerable from `data-contract.json` by re-running the pipeline.
