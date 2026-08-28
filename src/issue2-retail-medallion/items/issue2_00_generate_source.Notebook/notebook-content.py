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

# ## issue2_00_generate_source
#
# Stage 00 of the Issue #2 synthetic retail medallion.
#
# Writes the synthetic source CSVs to `Files/issue2/landing/`. Nothing outside
# `issue2_retail_lakehouse/Files/issue2/landing/**` is touched, which is the
# data-path allowlist entry this stage runs under.
#
# **There is no random number generator.** Every value is integer arithmetic over
# the row index, so a re-run regenerates the same content rather than new data.
# That is what makes the second-run idempotency assertion in stage 90 mean
# something: if this stage were random, a stable row count would prove only that
# the count was stable, not that the pipeline was idempotent.
#
# All identifiers arrive as parameters. This notebook resolves no workspace,
# lakehouse or item by name, convention or search.

# PARAMETERS CELL ********************

# Bound at run time by the pipeline, which is in turn bound by
# scripts/fabric/Deploy-Issue2Medallion.ps1 from config/environment.local.json.
# Empty defaults are deliberate: an unbound run must fail loudly in the guard
# cell below rather than silently write somewhere plausible.
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
from datetime import date, timedelta

from pyspark.sql.types import StringType, StructField, StructType

# The data contract is substituted into this notebook at publish time from
# src/issue2-retail-medallion/data-contract.json. It is embedded rather than
# read from a path so that the definition deployed to Fabric and the definition
# reviewed in the repository cannot drift apart.
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

GEN = CONTRACT["generation"]
EXPECTED = CONTRACT["expected"]

print(f"run_token={run_token}")
print(f"landing={LANDING}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Reference dimensions -----------------------------------------------------
# Prices are held in integer cents and converted once, so the arithmetic that
# produces them carries no binary floating-point error into the source data.
# Any rounding difference observed downstream is then attributable to the
# transformation under test rather than to the generator.

REGIONS = ["North", "South", "East", "West"]
CATEGORIES = ["Beverages", "Bakery", "Produce", "Household", "Chilled"]
SEGMENTS = ["Premium", "Standard", "Value", "Occasional"]

store_rows = []
for s in range(1, GEN["storeCount"] + 1):
    store_rows.append(
        (
            str(s),
            f"Store {s:02d}",
            REGIONS[(s - 1) % len(REGIONS)],
            str(50 + ((s * 17) % 150)),  # floor area, a plausible store attribute
        )
    )

product_rows = []
for p in range(1, GEN["productCount"] + 1):
    unit_cost_cents = 250 + ((p * 37) % 900)
    unit_price_cents = (unit_cost_cents * 145 + 50) // 100  # 45% markup, rounded
    product_rows.append(
        (
            str(p),
            f"Product {p:03d}",
            CATEGORIES[(p - 1) % len(CATEGORIES)],
            f"{unit_cost_cents / 100:.2f}",
            f"{unit_price_cents / 100:.2f}",
        )
    )

customer_rows = []
for c in range(1, GEN["customerCount"] + 1):
    customer_rows.append(
        (
            str(c),
            f"Customer {c:04d}",
            SEGMENTS[(c - 1) % GEN["segmentCount"]],
            REGIONS[(c - 1) % len(REGIONS)],
        )
    )

# Price lookup used by the sales generator, keyed the same way the silver join
# will key it.
PRICE_BY_PRODUCT = {r[0]: r[4] for r in product_rows}

print(
    f"stores={len(store_rows)} products={len(product_rows)} "
    f"customers={len(customer_rows)}"
)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Clean sales lines --------------------------------------------------------
# One transaction per (day, store) with a fixed number of lines, so the Gold
# daily grain is exactly days x stores and the expected count is arithmetic
# rather than an observation.

START = date.fromisoformat(GEN["startDate"])

SALES_COLUMNS = [
    "source_row_id",
    "transaction_id",
    "line_number",
    "sales_date",
    "store_id",
    "product_id",
    "customer_id",
    "quantity",
    "unit_price",
    "discount_pct",
]

clean_rows = []
row_index = 0
for d in range(GEN["days"]):
    sales_date = (START + timedelta(days=d)).isoformat()
    for s in range(1, GEN["storeCount"] + 1):
        transaction_id = f"TX-{d:03d}-{s:02d}"
        for line in range(GEN["linesPerStoreDay"]):
            product_id = str((row_index % GEN["productCount"]) + 1)
            clean_rows.append(
                (
                    str(row_index),
                    transaction_id,
                    str(line + 1),
                    sales_date,
                    str(s),
                    product_id,
                    str((row_index % GEN["customerCount"]) + 1),
                    str((row_index % 5) + 1),
                    PRICE_BY_PRODUCT[product_id],
                    f"{(row_index % 4) * 5 / 100:.2f}",  # 0.00 / 0.05 / 0.10 / 0.15
                )
            )
            row_index += 1

assert len(clean_rows) == EXPECTED["sourceCleanSalesLines"], (
    f"clean line count {len(clean_rows)} != contract "
    f"{EXPECTED['sourceCleanSalesLines']}"
)
print(f"clean sales lines: {len(clean_rows)}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Injected defects ---------------------------------------------------------
# Each defect row starts from one clean template and mutates EXACTLY ONE field.
# That is what makes the expected quarantine breakdown exact: no row can be
# rejected for two reasons, so no reason can absorb another reason's count and
# hide a rule that never fired.
#
# Defect rows carry their own transaction_id namespace (TXD-) so that a defect
# is never also a duplicate. The two failure modes stay separable, which matters
# because they have different fixes: a rejected row is bad data, a duplicated
# row is good data delivered twice.

DEFECTS = GEN["injectedDefects"]
defect_rows = []
defect_index = 0


def defect_template(seq, **overrides):
    """A valid line in the TXD- namespace, with named fields overridden."""
    base = {
        "source_row_id": str(100000 + seq),
        "transaction_id": f"TXD-{seq:04d}",
        "line_number": "1",
        "sales_date": START.isoformat(),
        "store_id": "1",
        "product_id": "1",
        "customer_id": "1",
        "quantity": "2",
        "unit_price": PRICE_BY_PRODUCT["1"],
        "discount_pct": "0.05",
    }
    base.update(overrides)
    return tuple(base[c] for c in SALES_COLUMNS)


for _ in range(DEFECTS["nonPositiveQuantity"]):
    defect_rows.append(defect_template(defect_index, quantity="0"))
    defect_index += 1

for _ in range(DEFECTS["nullProductId"]):
    # Empty in CSV, which is how a missing natural key actually arrives.
    defect_rows.append(defect_template(defect_index, product_id=""))
    defect_index += 1

for _ in range(DEFECTS["orphanStoreId"]):
    defect_rows.append(
        defect_template(defect_index, store_id=str(GEN["orphanStoreIdValue"]))
    )
    defect_index += 1

for _ in range(DEFECTS["nonPositivePrice"]):
    defect_rows.append(defect_template(defect_index, unit_price="0.00"))
    defect_index += 1

# Duplicates are byte-copies of the business payload of the first N clean lines,
# differing only in source_row_id. They pass every quality rule and must be
# removed by deduplication, not by quarantine. Deduplication keeps the lowest
# source_row_id, so the ORIGINAL survives and the copy is dropped -- a
# deterministic choice rather than whichever row Spark happened to see first.
duplicate_rows = []
for i in range(DEFECTS["duplicateLines"]):
    original = list(clean_rows[i])
    original[0] = str(200000 + i)  # new source_row_id, everything else identical
    duplicate_rows.append(tuple(original))

sales_rows = clean_rows + defect_rows + duplicate_rows

assert len(defect_rows) + len(duplicate_rows) == EXPECTED["sourceInjectedDefectLines"], (
    f"injected line count {len(defect_rows) + len(duplicate_rows)} != contract "
    f"{EXPECTED['sourceInjectedDefectLines']}"
)
assert len(sales_rows) == EXPECTED["sourceTotalSalesLines"], (
    f"total line count {len(sales_rows)} != contract "
    f"{EXPECTED['sourceTotalSalesLines']}"
)
print(
    f"defect lines: {len(defect_rows)}  duplicate lines: {len(duplicate_rows)}  "
    f"total: {len(sales_rows)}"
)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Write the landing CSVs ---------------------------------------------------
# Everything lands as string. The source is a CSV drop, and pretending it
# arrives typed would move the parsing failures out of Silver where they are
# handled and into a layer that has no quarantine table to put them in.
#
# coalesce(1) keeps each dataset to a single part file so the landing area is
# reproducible across runs rather than varying with partition count.
# mode("overwrite") is what makes a re-run replace the landing area instead of
# doubling it.


def string_schema(columns):
    return StructType([StructField(c, StringType(), True) for c in columns])


def write_landing(rows, columns, name):
    df = spark.createDataFrame(rows, schema=string_schema(columns))
    target = f"{LANDING}/{name}"
    (
        df.coalesce(1)
        .write.mode("overwrite")
        .option("header", "true")
        .csv(target)
    )
    return target, df.count()


written = {}
for rows, columns, name in [
    (sales_rows, SALES_COLUMNS, "sales"),
    (store_rows, ["store_id", "store_name", "region", "floor_area_m2"], "stores"),
    (
        product_rows,
        ["product_id", "product_name", "category", "unit_cost", "list_price"],
        "products",
    ),
    (
        customer_rows,
        ["customer_id", "customer_name", "segment", "home_region"],
        "customers",
    ),
]:
    target, count = write_landing(rows, columns, name)
    written[name] = count
    print(f"wrote {count:>5} rows -> {target}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- Read back what was written -----------------------------------------------
# A successful write call is an accepted request. The row counts above come from
# the in-memory DataFrames, not from the lakehouse. Re-reading the CSVs from
# storage is what turns "the write did not raise" into "the data is there".

readback = {}
for name in ["sales", "stores", "products", "customers"]:
    readback[name] = (
        spark.read.option("header", "true").csv(f"{LANDING}/{name}").count()
    )

expected_landing = {
    "sales": EXPECTED["sourceTotalSalesLines"],
    "stores": GEN["storeCount"],
    "products": GEN["productCount"],
    "customers": GEN["customerCount"],
}

failures = [
    f"{k}: read back {readback[k]}, contract expects {v}"
    for k, v in expected_landing.items()
    if readback[k] != v
]
if failures:
    raise AssertionError("landing read-back mismatch: " + "; ".join(failures))

print("landing read-back matches the data contract:")
for k, v in readback.items():
    print(f"  {k:<10} {v}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
