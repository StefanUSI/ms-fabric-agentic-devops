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

# ## issue2_30_gold_build
#
# Stage 30 of the Issue #2 synthetic retail medallion.
#
# Builds three Gold tables, each answering a question a retail analyst actually
# asks:
#
# | Table | Grain | Question |
# |---|---|---|
# | `issue2_gold_daily_store_sales` | date x store | How is each store trading day to day? |
# | `issue2_gold_product_performance` | product | Which products earn their shelf space? |
# | `issue2_gold_customer_segment_kpi` | segment | What is each segment worth per head? |
#
# The three are aggregated from the **same** `issue2_silver_sales.net_amount`
# column along three independent grains. Stage 90 then sums all three back to a
# single total and requires them to agree. Grouping bugs are the realistic
# failure here -- a mis-specified join fan-out inflates one grain and not the
# others -- and this is the check that catches exactly that.
#
# Every join to a dimension is an inner join by intent, and Silver has already
# guaranteed there are no orphans: orphan rows were quarantined in stage 20 and
# never reached this layer.

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
TABLES = f"{LAKEHOUSE_ROOT}/Tables"

EXPECTED = CONTRACT["expected"]


def read_table(table):
    return spark.read.format("delta").load(f"{TABLES}/{table}")


def write_gold(df, table):
    df.write.mode("overwrite").option("overwriteSchema", "true").format("delta").save(
        f"{TABLES}/{table}"
    )
    print(f"{table:<36} written")


silver_sales = read_table("issue2_silver_sales")
dim_store = read_table("issue2_silver_dim_store")
dim_product = read_table("issue2_silver_dim_product")
dim_customer = read_table("issue2_silver_dim_customer")

print(f"run_token={run_token}   silver_sales rows: {silver_sales.count()}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Gold 1: daily store sales ------------------------------------------------
# The trading grain. transaction_count counts distinct transactions rather than
# lines, because a basket of seven items is one visit, and counting lines here
# would overstate footfall by the average basket size.

daily_store_sales = (
    silver_sales.groupBy("sales_date", "store_id")
    .agg(
        F.countDistinct("transaction_id").alias("transaction_count"),
        F.count(F.lit(1)).alias("line_count"),
        F.sum("quantity").cast("long").alias("units_sold"),
        F.sum("gross_amount").cast("decimal(18,2)").alias("gross_amount"),
        F.sum("discount_amount").cast("decimal(18,2)").alias("discount_amount"),
        F.sum("net_amount").cast("decimal(18,2)").alias("net_amount"),
    )
    .join(F.broadcast(dim_store.select("store_id", "store_name", "region")), "store_id")
    .withColumn(
        "avg_transaction_value",
        F.round(F.col("net_amount") / F.col("transaction_count"), 2).cast(
            "decimal(18,2)"
        ),
    )
    .withColumn("_built_run_token", F.lit(run_token))
    .select(
        "sales_date",
        "store_id",
        "store_name",
        "region",
        "transaction_count",
        "line_count",
        "units_sold",
        "gross_amount",
        "discount_amount",
        "net_amount",
        "avg_transaction_value",
        "_built_run_token",
    )
)

write_gold(daily_store_sales, "issue2_gold_daily_store_sales")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Gold 2: product performance ----------------------------------------------
# Margin is the point of this table. cost_amount uses the dimension's unit_cost
# rather than anything carried on the fact, so a cost correction lands in one
# place.
#
# margin_pct guards against a zero denominator explicitly. It cannot occur with
# this generated data -- every price is positive and non-positive prices are
# quarantined upstream -- but a divide-by-zero that "cannot happen" is still the
# cheapest possible thing to rule out, and leaving it unguarded would make this
# table fragile against a source change it should survive.

product_performance = (
    silver_sales.groupBy("product_id")
    .agg(
        F.count(F.lit(1)).alias("line_count"),
        F.sum("quantity").cast("long").alias("units_sold"),
        F.sum("net_amount").cast("decimal(18,2)").alias("net_revenue"),
    )
    .join(
        F.broadcast(
            dim_product.select("product_id", "product_name", "category", "unit_cost")
        ),
        "product_id",
    )
    .withColumn(
        "cost_amount",
        F.round(F.col("units_sold") * F.col("unit_cost"), 2).cast("decimal(18,2)"),
    )
    .withColumn(
        "margin_amount",
        (F.col("net_revenue") - F.col("cost_amount")).cast("decimal(18,2)"),
    )
    .withColumn(
        "margin_pct",
        F.when(
            F.col("net_revenue") > 0,
            F.round(F.col("margin_amount") / F.col("net_revenue"), 4),
        ).otherwise(F.lit(None)).cast("decimal(9,4)"),
    )
    .withColumn("_built_run_token", F.lit(run_token))
    .select(
        "product_id",
        "product_name",
        "category",
        "line_count",
        "units_sold",
        "unit_cost",
        "net_revenue",
        "cost_amount",
        "margin_amount",
        "margin_pct",
        "_built_run_token",
    )
)

write_gold(product_performance, "issue2_gold_product_performance")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Gold 3: customer segment KPIs --------------------------------------------
# active_customers counts distinct customers that actually transacted, not the
# size of the segment in the dimension. Revenue per *registered* customer and
# revenue per *active* customer are different numbers, and reporting the first
# under the second's name is the standard way this KPI goes wrong.

segment_kpi = (
    silver_sales.join(
        F.broadcast(dim_customer.select("customer_id", "segment")), "customer_id"
    )
    .groupBy("segment")
    .agg(
        F.countDistinct("customer_id").alias("active_customers"),
        F.countDistinct("transaction_id").alias("transaction_count"),
        F.count(F.lit(1)).alias("line_count"),
        F.sum("quantity").cast("long").alias("units_sold"),
        F.sum("net_amount").cast("decimal(18,2)").alias("net_revenue"),
    )
    .withColumn(
        "avg_transaction_value",
        F.round(F.col("net_revenue") / F.col("transaction_count"), 2).cast(
            "decimal(18,2)"
        ),
    )
    .withColumn(
        "revenue_per_active_customer",
        F.round(F.col("net_revenue") / F.col("active_customers"), 2).cast(
            "decimal(18,2)"
        ),
    )
    .withColumn("_built_run_token", F.lit(run_token))
    .select(
        "segment",
        "active_customers",
        "transaction_count",
        "line_count",
        "units_sold",
        "net_revenue",
        "avg_transaction_value",
        "revenue_per_active_customer",
        "_built_run_token",
    )
)

write_gold(segment_kpi, "issue2_gold_customer_segment_kpi")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Read back and reconcile against the contract -----------------------------
# Note what transaction_count does NOT do here: it is not summed across grains.
# A transaction spans one store-day but many products and one customer, so
# distinct counts are additive over the daily grain and not over the product
# grain. Only net_amount is grain-independent, which is why it is the measure
# stage 90 reconciles on.

observed = {
    t: spark.read.format("delta").load(f"{TABLES}/{t}").count()
    for t in EXPECTED["gold"].keys()
}

failures = [
    f"{t}: observed {observed[t]}, contract expects {n}"
    for t, n in EXPECTED["gold"].items()
    if observed.get(t) != n
]

for table, pk in EXPECTED["primaryKeys"].items():
    if not table.startswith("issue2_gold"):
        continue
    df = spark.read.format("delta").load(f"{TABLES}/{table}")
    total, distinct = df.count(), df.select(*pk).distinct().count()
    if total != distinct:
        failures.append(
            f"{table}: primary key {pk} is not unique ({total} rows, {distinct} keys)"
        )

if failures:
    raise AssertionError("gold reconciliation failed: " + "; ".join(failures))

print("gold read-back matches the data contract:")
for t, n in observed.items():
    print(f"  {t:<36} {n}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
