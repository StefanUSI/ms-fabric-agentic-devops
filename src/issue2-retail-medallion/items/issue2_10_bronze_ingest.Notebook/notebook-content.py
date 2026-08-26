# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "language_info": {
# META     "name": "python"
# META   }
# META }

# MARKDOWN ********************

# ## issue2_10_bronze_ingest
#
# Stage 10 of the Issue #2 synthetic retail medallion.
#
# Reads `Files/issue2/landing/**` and writes the four Bronze Delta tables.
#
# **Bronze does not clean.** Every column stays a string, every row survives
# including the injected defects and the duplicates, and no join is attempted.
# The defects have to reach Silver intact, because Silver's quarantine counts
# are the evidence that the quality rules ran at all. A Bronze layer that
# quietly dropped a bad row would make the whole quarantine table look correct
# and empty at the same time.
#
# The only columns added are ingestion lineage, which is the one thing Bronze
# knows that the source file does not.

# PARAMETERS CELL ********************

workspace_id = ""
lakehouse_id = ""
run_token = ""

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

import json

from pyspark.sql import functions as F

CONTRACT = json.loads(r"""{{DATA_CONTRACT_JSON}}""")

if not workspace_id or not lakehouse_id or not run_token:
    raise ValueError(
        "workspace_id, lakehouse_id and run_token are all required. "
        "This notebook never infers an identifier."
    )

LAKEHOUSE_ROOT = (
    f"abfss://{workspace_id}@onelake.dfs.fabric.microsoft.com/{lakehouse_id}"
)
LANDING = f"{LAKEHOUSE_ROOT}/Files/issue2/landing"
TABLES = f"{LAKEHOUSE_ROOT}/Tables"

EXPECTED_BRONZE = CONTRACT["expected"]["bronze"]

# Landing dataset -> Bronze table. Both halves are named explicitly; nothing is
# discovered by listing the landing directory, so a stray file that appears
# there cannot become a table.
INGESTS = [
    ("sales", "issue2_bronze_sales"),
    ("stores", "issue2_bronze_stores"),
    ("products", "issue2_bronze_products"),
    ("customers", "issue2_bronze_customers"),
]

print(f"run_token={run_token}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Land Bronze --------------------------------------------------------------
# overwrite, not append. This is the whole idempotency story for Bronze: the
# landing area is regenerated deterministically upstream, so replacing the table
# reproduces it. Appending would double the row count on every re-run and the
# row-conservation identity in stage 90 would fail on the second pass.

for dataset, table in INGESTS:
    df = (
        spark.read.option("header", "true")
        .csv(f"{LANDING}/{dataset}")
        # Lineage only. inputFiles() is not used because the landing path is
        # already known and recording it per row costs nothing.
        .withColumn("_ingested_run_token", F.lit(run_token))
        .withColumn("_ingested_at_utc", F.current_timestamp())
        .withColumn("_source_dataset", F.lit(dataset))
    )
    df.write.mode("overwrite").option("overwriteSchema", "true").format("delta").save(
        f"{TABLES}/{table}"
    )
    print(f"{table:<28} written")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Read back and reconcile against the contract -----------------------------
# The counts are read from the Delta tables after the write, and compared to
# values declared in the repository before the run. Comparing the write to
# itself would pass unconditionally.

observed = {
    table: spark.read.format("delta").load(f"{TABLES}/{table}").count()
    for _, table in INGESTS
}

failures = [
    f"{t}: observed {observed[t]}, contract expects {n}"
    for t, n in EXPECTED_BRONZE.items()
    if observed.get(t) != n
]
if failures:
    raise AssertionError("bronze row-count mismatch: " + "; ".join(failures))

print("bronze read-back matches the data contract:")
for t, n in observed.items():
    print(f"  {t:<28} {n}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
