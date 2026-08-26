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

# ## issue2_20_silver_transform
#
# Stage 20 of the Issue #2 synthetic retail medallion.
#
# Turns the untyped Bronze tables into a typed, validated, deduplicated Silver
# layer plus a quarantine table.
#
# ### Two failure modes, kept apart
#
# A row can be **wrong** or it can be **repeated**, and those are different
# problems with different fixes. This notebook handles them in separate steps
# and counts them separately:
#
# * **Rejected** rows fail a quality rule. They go to
#   `issue2_silver_quarantine_sales` with the reason attached, and they are
#   never silently dropped -- a rejected row that vanished would be
#   indistinguishable from a row that was never sent.
# * **Duplicate** rows pass every rule and are simply delivered twice. They are
#   removed by deduplication, keeping the lowest `source_row_id`, and counted.
#
# Because the two are separated, stage 90 can assert the row-conservation
# identity `bronze = silver + quarantined + deduplicated` and have it mean
# something. If rejection and deduplication shared a bucket, the identity would
# still balance while the individual causes were wrong.
#
# ### Rule precedence is first-match-wins
#
# Rules are evaluated in the order declared in the data contract and a row
# carries exactly one reason. Without a fixed precedence a row with a null
# `product_id` would be both `null_natural_key` and `orphan_product`, the two
# counts would overlap, and the contract's exact expected breakdown would be
# unassertable.

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

from pyspark.sql import Window
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
TABLES = f"{LAKEHOUSE_ROOT}/Tables"

EXPECTED = CONTRACT["expected"]
MAX_DISCOUNT = 0.9  # matches the invalid_discount rule text in the contract


def read_bronze(table):
    return spark.read.format("delta").load(f"{TABLES}/{table}")


def write_silver(df, table):
    df.write.mode("overwrite").option("overwriteSchema", "true").format("delta").save(
        f"{TABLES}/{table}"
    )
    print(f"{table:<32} written")


def blank_to_null(column):
    """CSV delivers a missing value as an empty string, not as NULL."""
    trimmed = F.trim(F.col(column))
    return F.when(trimmed == "", None).otherwise(trimmed)


print(f"run_token={run_token}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Silver dimensions --------------------------------------------------------
# The dimensions are built first because the fact's orphan rules are defined
# against them. Deriving "is this store real?" from anything other than the
# dimension the Gold layer will later join to would let a row pass validation
# and then disappear in an inner join downstream.

dim_store = (
    read_bronze("issue2_bronze_stores")
    .select(
        F.col("store_id").cast("int").alias("store_id"),
        F.col("store_name"),
        F.col("region"),
        F.col("floor_area_m2").cast("int").alias("floor_area_m2"),
    )
    .where(F.col("store_id").isNotNull())
    .dropDuplicates(["store_id"])
)

dim_product = (
    read_bronze("issue2_bronze_products")
    .select(
        F.col("product_id").cast("int").alias("product_id"),
        F.col("product_name"),
        F.col("category"),
        F.col("unit_cost").cast("decimal(18,4)").alias("unit_cost"),
        F.col("list_price").cast("decimal(18,4)").alias("list_price"),
    )
    .where(F.col("product_id").isNotNull())
    .dropDuplicates(["product_id"])
)

dim_customer = (
    read_bronze("issue2_bronze_customers")
    .select(
        F.col("customer_id").cast("int").alias("customer_id"),
        F.col("customer_name"),
        F.col("segment"),
        F.col("home_region"),
    )
    .where(F.col("customer_id").isNotNull())
    .dropDuplicates(["customer_id"])
)

write_silver(dim_store, "issue2_silver_dim_store")
write_silver(dim_product, "issue2_silver_dim_product")
write_silver(dim_customer, "issue2_silver_dim_customer")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Type the fact ------------------------------------------------------------
# Casting is the first quality gate and it is deliberately non-destructive: an
# unparseable value becomes NULL and is then rejected by a named rule, rather
# than throwing and taking the whole run down. One bad row should quarantine one
# row, not fail a pipeline.
#
# Money is decimal, never double. A retail margin computed in binary floating
# point drifts, and the reconciliation in stage 90 would then be measuring the
# arithmetic instead of the transformation.

typed = (
    read_bronze("issue2_bronze_sales")
    .select(
        F.col("source_row_id").cast("long").alias("source_row_id"),
        blank_to_null("transaction_id").alias("transaction_id"),
        blank_to_null("line_number").cast("int").alias("line_number"),
        F.to_date(blank_to_null("sales_date"), "yyyy-MM-dd").alias("sales_date"),
        blank_to_null("store_id").cast("int").alias("store_id"),
        blank_to_null("product_id").cast("int").alias("product_id"),
        blank_to_null("customer_id").cast("int").alias("customer_id"),
        blank_to_null("quantity").cast("int").alias("quantity"),
        blank_to_null("unit_price").cast("decimal(18,4)").alias("unit_price"),
        blank_to_null("discount_pct").cast("decimal(9,4)").alias("discount_pct"),
        F.col("_ingested_run_token"),
    )
)

# Referential markers for the orphan rules. Left joins, so a miss produces NULL
# and is classified by rule rather than removing the row from the pipeline.
marked = (
    typed.join(
        F.broadcast(dim_store.select("store_id").withColumn("_store_exists", F.lit(1))),
        on="store_id",
        how="left",
    ).join(
        F.broadcast(
            dim_product.select("product_id").withColumn("_product_exists", F.lit(1))
        ),
        on="product_id",
        how="left",
    )
)

print(f"typed rows: {marked.count()}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Quality rules, first match wins ------------------------------------------
# The order below is the order in CONTRACT["dataQualityRules"]. A row gets
# exactly one reason, so the expected per-reason counts are exact and a reason
# that never matches shows as 0 rather than as an absent key. Zero is a real
# assertion -- it says the rule ran and found nothing. An absent key would say
# nothing at all.

reject_reason = (
    F.when(
        F.col("transaction_id").isNull()
        | F.col("line_number").isNull()
        | F.col("product_id").isNull(),
        F.lit("null_natural_key"),
    )
    .when(
        F.col("quantity").isNull() | (F.col("quantity") <= 0),
        F.lit("non_positive_quantity"),
    )
    .when(
        F.col("unit_price").isNull() | (F.col("unit_price") <= 0),
        F.lit("non_positive_price"),
    )
    .when(F.col("_store_exists").isNull(), F.lit("orphan_store"))
    .when(F.col("_product_exists").isNull(), F.lit("orphan_product"))
    .when(
        F.col("discount_pct").isNull()
        | (F.col("discount_pct") < 0)
        | (F.col("discount_pct") > F.lit(MAX_DISCOUNT).cast("decimal(9,4)")),
        F.lit("invalid_discount"),
    )
    .otherwise(F.lit(None).cast("string"))
)

classified = marked.withColumn("reject_reason", reject_reason).cache()

quarantine = (
    classified.where(F.col("reject_reason").isNotNull())
    .drop("_store_exists", "_product_exists")
    .withColumn("_quarantined_run_token", F.lit(run_token))
    .withColumn("_quarantined_at_utc", F.current_timestamp())
)

passed = classified.where(F.col("reject_reason").isNull()).drop(
    "_store_exists", "_product_exists", "reject_reason"
)

quarantine_count = quarantine.count()
passed_count = passed.count()
print(f"passed quality rules: {passed_count}   quarantined: {quarantine_count}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Deduplicate --------------------------------------------------------------
# Runs only over rows that already passed the quality rules, so a duplicated bad
# row is quarantined once rather than being deduplicated into invisibility.
#
# The survivor is chosen by lowest source_row_id, not by arbitrary order. Spark
# offers no stable "first row" without an explicit ordering, so "keep one" would
# otherwise be a different row each run and the layer would stop being
# reproducible even though its row count looked stable.

key = ["transaction_id", "line_number"]
ranked = passed.withColumn(
    "_rn",
    F.row_number().over(Window.partitionBy(*key).orderBy(F.col("source_row_id").asc())),
)

deduped = ranked.where(F.col("_rn") == 1).drop("_rn")
deduped_count = deduped.count()
duplicates_removed = passed_count - deduped_count

print(f"deduplicated to: {deduped_count}   duplicates removed: {duplicates_removed}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Derive the measures and write Silver -------------------------------------
# net_amount is computed once, here, and every Gold aggregate sums this same
# column. That is deliberate: it makes the three-way financial agreement in
# stage 90 a check that the aggregations group correctly, rather than a check
# that three separate re-derivations of the same formula happen to round the
# same way.

silver_sales = (
    deduped.withColumn(
        "gross_amount",
        F.round(F.col("quantity") * F.col("unit_price"), 2).cast("decimal(18,2)"),
    )
    .withColumn(
        "net_amount",
        F.round(
            F.col("quantity") * F.col("unit_price") * (F.lit(1) - F.col("discount_pct")),
            2,
        ).cast("decimal(18,2)"),
    )
    .withColumn(
        "discount_amount",
        (F.col("gross_amount") - F.col("net_amount")).cast("decimal(18,2)"),
    )
    .withColumn("_transformed_run_token", F.lit(run_token))
    .select(
        "transaction_id",
        "line_number",
        "sales_date",
        "store_id",
        "product_id",
        "customer_id",
        "quantity",
        "unit_price",
        "discount_pct",
        "gross_amount",
        "discount_amount",
        "net_amount",
        "source_row_id",
        "_transformed_run_token",
    )
)

write_silver(silver_sales, "issue2_silver_sales")
write_silver(quarantine, "issue2_silver_quarantine_sales")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Read back and reconcile against the contract -----------------------------
# Counts below come from the Delta tables after the write, not from the
# DataFrames that produced them, and are compared against values declared in the
# repository before the run.

observed = {
    t: spark.read.format("delta").load(f"{TABLES}/{t}").count()
    for t in EXPECTED["silver"].keys()
}

failures = [
    f"{t}: observed {observed[t]}, contract expects {n}"
    for t, n in EXPECTED["silver"].items()
    if observed.get(t) != n
]

# Per-reason breakdown, read back from the quarantine table.
reason_counts = {
    r["reject_reason"]: r["n"]
    for r in spark.read.format("delta")
    .load(f"{TABLES}/issue2_silver_quarantine_sales")
    .groupBy("reject_reason")
    .agg(F.count(F.lit(1)).alias("n"))
    .collect()
}
for reason, expected_n in EXPECTED["quarantineByReason"].items():
    actual_n = reason_counts.get(reason, 0)
    if actual_n != expected_n:
        failures.append(
            f"quarantine[{reason}]: observed {actual_n}, contract expects {expected_n}"
        )

if duplicates_removed != EXPECTED["duplicatesRemoved"]:
    failures.append(
        f"duplicatesRemoved: observed {duplicates_removed}, "
        f"contract expects {EXPECTED['duplicatesRemoved']}"
    )

# Primary-key uniqueness, asserted on the written table rather than assumed from
# the deduplication step that was supposed to guarantee it.
for table, pk in EXPECTED["primaryKeys"].items():
    if not table.startswith("issue2_silver"):
        continue
    df = spark.read.format("delta").load(f"{TABLES}/{table}")
    total, distinct = df.count(), df.select(*pk).distinct().count()
    if total != distinct:
        failures.append(
            f"{table}: primary key {pk} is not unique ({total} rows, {distinct} keys)"
        )

if failures:
    raise AssertionError("silver reconciliation failed: " + "; ".join(failures))

print("silver read-back matches the data contract:")
for t, n in observed.items():
    print(f"  {t:<32} {n}")
print(f"  quarantine by reason: {reason_counts}")
print(f"  duplicates removed  : {duplicates_removed}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
