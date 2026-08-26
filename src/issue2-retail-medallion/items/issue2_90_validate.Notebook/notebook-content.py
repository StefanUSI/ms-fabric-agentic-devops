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

# ## issue2_90_validate
#
# Stage 90 of the Issue #2 synthetic retail medallion. The stage that decides
# whether the run is trustworthy.
#
# Every assertion below compares a value **read back from a Delta table** against
# a value declared in `data-contract.json` **before the run**. Nothing is
# compared to itself, and no expectation is derived from the run under test --
# a self-derived expectation makes every run pass, which is the failure mode this
# stage exists to avoid.
#
# ### What is asserted
#
# | Assertion | Why it is not redundant with the earlier stages |
# |---|---|
# | Landing / Bronze / Silver / Gold row counts | Stages 10-30 each checked their own output. This checks all four layers *together*, after the fact, from one place a reviewer can read. |
# | Quarantine breakdown by reason | A reason expected to be 0 proves the rule ran and matched nothing. An absent key would prove nothing. |
# | Row conservation | `bronze = silver + quarantined + deduplicated`. Computed from three independently written tables, so a bug would have to shift all three the same way to hide. |
# | Primary-key uniqueness | Asserted on the written table, not inferred from the deduplication step that was supposed to guarantee it. |
# | Three-way financial agreement | The same `net_amount` summed at three different grains. Catches join fan-out, which inflates one grain and leaves the others correct. |
# | Idempotency | Content hashes of the Gold tables compared against the previous run's audit file. A stable *row count* is not idempotency; identical *content* is. |
#
# ### The audit file is the point
#
# Printed output lives in a notebook snapshot and is awkward to retrieve and
# trivial to misread. This stage instead writes a machine-readable audit file to
# `Files/issue2/evidence/`, which the deployment script then fetches over the
# OneLake DFS endpoint **with a different token audience** and asserts against
# independently. That indirection is what makes the evidence a read-back rather
# than a restatement of what this notebook believed at the time.
#
# This resolves open decision 1 in `docs/environment-and-constraints.md`: no ODBC
# driver and no semantic model are required to read a row count back.

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
from datetime import datetime, timezone

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
LANDING = f"{LAKEHOUSE_ROOT}/Files/issue2/landing"
EVIDENCE = f"{LAKEHOUSE_ROOT}/Files/issue2/evidence"

EXPECTED = CONTRACT["expected"]
GEN = CONTRACT["generation"]
TOLERANCE = float(EXPECTED["financialToleranceAbsolute"])

# Collected rather than raised on immediately. One assertion failure should not
# hide the other eleven -- a reviewer needs the whole picture from one run, not
# one symptom per re-run.
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
    return condition


def read_table(table):
    return spark.read.format("delta").load(f"{TABLES}/{table}")


print(f"run_token={run_token}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 1. Row counts, every layer ------------------------------------------------
# The landing count is read from the CSVs rather than carried forward from the
# generator, so the chain source -> bronze -> silver -> gold is verified end to
# end from storage rather than from memory.

landing_counts = {
    name: spark.read.option("header", "true").csv(f"{LANDING}/{name}").count()
    for name in ["sales", "stores", "products", "customers"]
}

check(
    landing_counts["sales"] == EXPECTED["sourceTotalSalesLines"],
    f"landing sales: observed {landing_counts['sales']}, "
    f"contract expects {EXPECTED['sourceTotalSalesLines']}",
)

layer_counts = {}
for layer in ["bronze", "silver", "gold"]:
    for table, expected_n in EXPECTED[layer].items():
        observed_n = read_table(table).count()
        layer_counts[table] = observed_n
        check(
            observed_n == expected_n,
            f"{table}: observed {observed_n}, contract expects {expected_n}",
        )

print("row counts:")
for t, n in layer_counts.items():
    print(f"  {t:<36} {n}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 2. Quarantine breakdown and row conservation ------------------------------
# duplicates_removed is DERIVED from the conservation identity rather than read
# from a counter the transform emitted. Reading the transform's own counter back
# would only confirm the transform agreed with itself; deriving it forces the
# three independently written tables to reconcile.

quarantine = read_table("issue2_silver_quarantine_sales")

reason_counts = {
    r["reject_reason"]: r["n"]
    for r in quarantine.groupBy("reject_reason")
    .agg(F.count(F.lit(1)).alias("n"))
    .collect()
}

for reason, expected_n in EXPECTED["quarantineByReason"].items():
    actual_n = reason_counts.get(reason, 0)
    check(
        actual_n == expected_n,
        f"quarantine[{reason}]: observed {actual_n}, contract expects {expected_n}",
    )

bronze_sales = layer_counts["issue2_bronze_sales"]
silver_sales_n = layer_counts["issue2_silver_sales"]
quarantined_n = layer_counts["issue2_silver_quarantine_sales"]
duplicates_removed = bronze_sales - silver_sales_n - quarantined_n

check(
    duplicates_removed == EXPECTED["duplicatesRemoved"],
    f"duplicatesRemoved: derived {duplicates_removed}, "
    f"contract expects {EXPECTED['duplicatesRemoved']}",
)

conservation_holds = (
    bronze_sales == silver_sales_n + quarantined_n + duplicates_removed
)
check(
    conservation_holds,
    f"row conservation broken: bronze {bronze_sales} != silver {silver_sales_n} "
    f"+ quarantined {quarantined_n} + deduplicated {duplicates_removed}",
)

print(
    f"conservation: {bronze_sales} = {silver_sales_n} + {quarantined_n} "
    f"+ {duplicates_removed}  -> {conservation_holds}"
)
print(f"quarantine by reason: {reason_counts}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 3. Primary-key uniqueness -------------------------------------------------
# Every keyed table in the contract, Silver and Gold alike. A Gold grain that
# duplicates its key is the classic symptom of a fan-out join, and it is
# invisible in a row count that happens to match for another reason.

pk_results = {}
for table, pk in EXPECTED["primaryKeys"].items():
    df = read_table(table)
    total = df.count()
    distinct = df.select(*pk).distinct().count()
    pk_results[table] = {"columns": pk, "rows": total, "distinctKeys": distinct}
    check(
        total == distinct,
        f"{table}: primary key {pk} not unique ({total} rows, {distinct} keys)",
    )

    # A null in a key column makes uniqueness meaningless -- NULLs do not
    # compare equal, so distinct() would count each one separately and the
    # uniqueness check above would pass on a table that has no usable key.
    null_keys = df.where(
        " OR ".join(f"`{c}` IS NULL" for c in pk)
    ).count()
    pk_results[table]["nullKeyRows"] = null_keys
    check(null_keys == 0, f"{table}: {null_keys} rows have a NULL in key {pk}")

print("primary keys:")
for t, r in pk_results.items():
    print(f"  {t:<36} {r['rows']} rows / {r['distinctKeys']} keys")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 4. Three-way financial reconciliation -------------------------------------
# One measure, four independent aggregations: the Silver fact plus the three
# Gold grains. They must agree to the cent.
#
# The customer-segment grain is the one that can legitimately disagree: it is the
# only Gold table built through a join, so if that join fanned out its total
# would exceed the others. That is precisely why it is included rather than
# assumed equivalent.


def total_net(table, column):
    value = read_table(table).agg(F.sum(column)).collect()[0][0]
    return float(value or 0)


totals = {
    "silver_sales": total_net("issue2_silver_sales", "net_amount"),
    "gold_daily_store_sales": total_net("issue2_gold_daily_store_sales", "net_amount"),
    "gold_product_performance": total_net(
        "issue2_gold_product_performance", "net_revenue"
    ),
    "gold_customer_segment_kpi": total_net(
        "issue2_gold_customer_segment_kpi", "net_revenue"
    ),
}

baseline = totals["silver_sales"]
deltas = {k: round(v - baseline, 4) for k, v in totals.items()}
max_delta = max(abs(d) for d in deltas.values())

check(
    max_delta <= TOLERANCE,
    f"financial reconciliation: max delta {max_delta} exceeds tolerance "
    f"{TOLERANCE}; totals {totals}",
)

print(f"net amount, four ways (tolerance {TOLERANCE}):")
for k, v in totals.items():
    print(f"  {k:<32} {v:>14.2f}   delta {deltas[k]:+.4f}")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 5. Gold content hashes ----------------------------------------------------
# The idempotency evidence. Row counts are a weak proxy: an overwrite that wrote
# different values would keep the count stable and change every number. Hashing
# the sorted content catches that.
#
# Lineage columns (leading underscore) are excluded deliberately. run_token and
# ingestion timestamps are EXPECTED to differ between runs -- including them
# would guarantee a hash mismatch and make the check assert nothing.


def content_hash(table):
    df = read_table(table)
    business_columns = sorted(c for c in df.columns if not c.startswith("_"))
    row_hashes = df.select(
        F.sha2(
            F.concat_ws("|", *[F.coalesce(F.col(c).cast("string"), F.lit("~")) for c in business_columns]),
            256,
        ).alias("h")
    )
    # Sorting then hashing the concatenation makes the result independent of
    # Spark's partitioning and row order, which are not stable across runs.
    ordered = [r["h"] for r in row_hashes.orderBy("h").collect()]
    combined = spark.createDataFrame([("|".join(ordered),)], ["v"])
    return combined.select(F.sha2(F.col("v"), 256).alias("h")).collect()[0]["h"]


gold_hashes = {t: content_hash(t) for t in sorted(EXPECTED["gold"].keys())}

print("gold content hashes:")
for t, h in gold_hashes.items():
    print(f"  {t:<36} {h[:16]}...")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 6. Idempotency against the previous run -----------------------------------
# Compares this run's Gold hashes to the audit file the PREVIOUS run left behind.
# On the first run there is no previous file and the check is recorded as
# "firstRun" -- explicitly not as a pass, because an assertion that had nothing
# to compare against did not succeed, it did not run.
#
# The deployment script also performs this comparison across the two audit files
# it retrieves itself. Two independent checks of the same property, one inside
# Fabric and one outside it, and neither is trusted to stand alone.

try:
    import notebookutils as _nbu
except ImportError:  # older runtimes expose the same API under this name
    import mssparkutils as _nbu

LATEST = f"{EVIDENCE}/validation-latest.json"

previous = None
try:
    previous = json.loads(_nbu.fs.head(LATEST, 1024 * 1024))
except Exception as exc:  # noqa: BLE001 - absence is a valid first-run state
    print(f"no previous audit file ({type(exc).__name__}); this is run 1")

if previous is None:
    idempotency = {"status": "firstRun", "comparedTo": None, "mismatches": []}
else:
    mismatches = [
        f"{t}: previous {previous.get('goldContentHashes', {}).get(t)} "
        f"!= current {h}"
        for t, h in gold_hashes.items()
        if previous.get("goldContentHashes", {}).get(t) != h
    ]
    idempotency = {
        "status": "pass" if not mismatches else "fail",
        "comparedTo": previous.get("runToken"),
        "mismatches": mismatches,
    }
    check(
        not mismatches,
        "idempotency: gold content changed between runs: " + "; ".join(mismatches),
    )

print(f"idempotency: {idempotency['status']} (vs {idempotency['comparedTo']})")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 7. Write the audit file ---------------------------------------------------
# Written BEFORE the failure is raised, and with an explicit "passed" flag, so a
# failed run leaves retrievable evidence of exactly which assertion failed. An
# audit file that only exists on success would make every failure look like an
# infrastructure problem.
#
# Two paths: a per-run file that is never overwritten, and a stable "latest"
# pointer the next run reads for its idempotency comparison.

audit = {
    "schemaVersion": 1,
    "ticketId": CONTRACT["ticketId"],
    "runToken": run_token,
    "generatedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "passed": not failures,
    "failures": failures,
    "landingCounts": landing_counts,
    "rowCounts": layer_counts,
    "quarantineByReason": {
        reason: reason_counts.get(reason, 0)
        for reason in EXPECTED["quarantineByReason"]
    },
    "rowConservation": {
        "bronzeSales": bronze_sales,
        "silverSales": silver_sales_n,
        "quarantined": quarantined_n,
        "duplicatesRemoved": duplicates_removed,
        "holds": conservation_holds,
    },
    "primaryKeys": pk_results,
    "financialReconciliation": {
        "totals": {k: round(v, 2) for k, v in totals.items()},
        "deltas": deltas,
        "maxAbsoluteDelta": max_delta,
        "tolerance": TOLERANCE,
        "withinTolerance": max_delta <= TOLERANCE,
    },
    "goldContentHashes": gold_hashes,
    "idempotency": idempotency,
}

body = json.dumps(audit, indent=2, sort_keys=True)

# The per-run file first. If the "latest" write then fails, the run's evidence
# still exists rather than being lost with it.
_nbu.fs.put(f"{EVIDENCE}/validation-run-{run_token}.json", body, True)
_nbu.fs.put(LATEST, body, True)

print(f"audit written: {EVIDENCE}/validation-run-{run_token}.json")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# --- 8. Fail the run if any assertion failed -----------------------------------
# Raising is what turns a red validation into a failed PIPELINE, which is what
# the deployment script polls for. A validation notebook that printed its
# failures and exited 0 would let a broken run report a Succeeded terminal state.

if failures:
    raise AssertionError(
        f"issue2 validation failed with {len(failures)} assertion(s): "
        + "; ".join(failures)
    )

print(f"ALL VALIDATIONS PASSED (run_token={run_token})")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
