# Amazon NFT — European Fulfillment Network Flow Optimization

SQL analysis of a multi-echelon European fulfillment network identifying stockout root causes and quantifying the cost impact of push vs pull replenishment — recommending a pull model that reduces idle inventory 5x and cuts stockout rate by 50%.

---

## Business Question

> **How should inventory move through a multi-echelon fulfillment network to guarantee customer order fulfilment within 24 hours at the lowest possible cost?**

This project simulates the operational reality of Amazon's Network Flow and Technologies (NFT) team — the team responsible for transforming Europe's inbound fulfillment network from a forecast-driven push model to a demand-driven pull model.

---

## Network Structure

```
SUPPLIER
    ↓
1DC / RDC          ← Bulk upstream storage and buffering
    ↓
IXD                ← Inbound Cross Dock (sorting and transit only)
    ↓
FC                 ← Fulfillment Center (pick, pack, dispatch)
    ↓
NEXUS              ← Last mile city dispatch hub
    ↓
CUSTOMER
```

The network covers **24 nodes** across Spain, France, Germany and the Netherlands:
- 5 x First Distribution Centers (1DC)
- 3 x Regional Distribution Centers (RDC)
- 4 x Inbound Cross Docks (IXD)
- 8 x Fulfillment Centers (FC)
- 4 x Nexus last-mile nodes

---

## Dataset

| Table | Rows | Description |
|---|---|---|
| suppliers | 10 | Vendor master data with lead times and reliability scores |
| nodes | 24 | Network location master across 5 countries |
| skus | 250 | Product catalogue with velocity and demand profiles |
| purchase_orders | 125 | Supplier replenishment orders Sep–Dec 2024 |
| inventory | 1,312 | Current stock levels across all storage nodes |
| transfers | 2,860 | 120 days of actual shipment movements |
| replenishment_comparison | 4,849 | Push vs pull modelled scenarios side by side |
| orders | 16,615 | 60 days of customer order history with seasonality |
| sla_performance | 1,280 | Transit time measurements per route |
| **Total** | **27,325** | **9 related tables \| 4 months of data** |

**Note:** This is a synthetic dataset generated to mirror the structure and complexity of a real Amazon European fulfillment network. All company names, locations, and figures are simulated.

---

## Analysis Structure

### Section 1 — Network Baseline
Understanding current inventory distribution, capacity utilisation, and storage cost structure across all node types.

### Section 2 — Where is the Network Failing
Identifying stockout patterns by fulfillment center, SKU velocity, product category, and promotional demand periods.

### Section 3 — Why is it Failing (Root Cause)
Tracing stockout causes upstream — supplier PO failures, SLA transit breaches, and IXD capacity pressure.

### Section 4 — Push vs Pull Model Comparison
Quantifying the cost, idle inventory, and stockout rate implications of switching from forecast-driven push to demand-driven pull replenishment.

---

## Key Findings

| # | Finding |
|---|---|
| 1 | All node types operate at ~40% capacity — the network treats every node identically regardless of its role or cost structure |
| 2 | FC storage is the most expensive per unit yet holds the same utilisation as cheaper upstream nodes |
| 3 | Overall stockout rate is ~7%, rising to 13% during promotional periods — a 100% increase during known demand events |
| 4 | Two distinct stockout failure modes: 663 events with no PO raised (ordering failure) and 490 events despite PO existing (timing/demand failure) |
| 5 | Stockout SKUs frequently had active transfers on the same date — inventory existed in the network but was misrouted |
| 6 | IXD capacity is breached on peak days in Madrid and Paris — cumulative inflow exceeds stated node capacity |
| 7 | Push model generates **5x more idle inventory days** than pull |
| 8 | Push costs more AND has a higher stockout rate — it loses on every performance dimension simultaneously |

---

## Core Business Case — Push vs Pull

The `replenishment_comparison` table models every replenishment event twice — once under push logic (forecast triggered) and once under pull logic (reorder point triggered). This enables direct side-by-side comparison for the same SKU at the same FC on the same date.

| Metric | Push Model | Pull Model | Improvement |
|---|---|---|---|
| Avg idle inventory days | ~8.5 days | ~1.7 days | **5x reduction** |
| Stockout rate | ~8% | ~4% | **50% reduction** |
| Replenishment cost | Higher | Lower | Pull wins consistently |

**The paradox of push:** Push over-orders based on forecast, clogs FC storage with idle inventory at the most expensive node in the network, reduces flexibility to respond to actual demand spikes, and paradoxically creates the stockouts it was designed to prevent.

---

## Recommendations

1. **Transition to pull-based replenishment** — pilot at FC_BCN1 and FC_MAD1 where push over-ordering is most pronounced, before network-wide rollout

2. **Implement pre-promotional positioning protocol** — pre-position inventory upstream minimum 2 weeks before known demand events (Black Friday, seasonal peaks) to prevent the 13% promotional stockout rate

3. **Resolve IXD capacity constraints** — address cumulative flow buildup at Madrid and Paris IXDs before implementing any consolidation recommendations

4. **Fix reorder trigger failures** — 663 stockout events had no PO raised at all, indicating the reorder point system is not consistently firing — requires process audit

5. **Improve delay reason categorisation** — the most frequent SLA delay reason is uncategorised ("other"), masking true root causes — a Gemba walk and system update is recommended

---

## Limitations

- Dataset is synthetic — patterns are directionally realistic but not derived from real Amazon operational data
- Inventory table is a static snapshot — historical stock levels at order time are not available, limiting stockout-to-inventory causal analysis
- Push vs pull comparison is modelled, not observed — actual historical replenishment decisions are not captured in this dataset
- Sample size of 27,325 rows limits statistical confidence on some findings that would be clearer at production scale (millions of rows)

---

## Tools and Skills Demonstrated

| Tool / Skill | Application |
|---|---|
| MySQL 8.0 | All data querying and analysis |
| CTEs (Common Table Expressions) | IXD cumulative flow analysis |
| Window Functions | Running totals, percentage of total calculations |
| Multi-table JOINs | Cross-table root cause tracing |
| CASE WHEN pivoting | Push vs pull side-by-side comparison |
| Subqueries | Stockout risk categorisation |
| Aggregate functions | Network-wide KPI calculation |

---

## How to Reproduce

1. Download all CSV files from this repository
2. Create a MySQL database: `CREATE DATABASE amazon_portfolio;`
3. Load each CSV using MySQL Workbench import wizard or `LOAD DATA INFILE`
4. Run queries from `amazon_nft_analysis.sql` section by section

---

## Author

**Louis Oigbochie**  
MBA — IESE Business School Barcelona / NYU Stern (Exchange)  
APICS Certified Supply Chain Professional (CSCP)  
[LinkedIn](https://www.linkedin.com/in/louis-oigbochie)

---

*This project was built as part of a supply chain analytics portfolio targeting senior process improvement roles in European fulfillment network operations.*
