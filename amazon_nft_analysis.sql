-- ============================================================
-- PROJECT: Amazon NFT European Fulfillment Network Analysis
-- Author:  Louis Oigbochie
-- Tools:   MySQL 8.0
-- Dataset: Synthetic multi-echelon European fulfillment network
--          9 tables | 27,325 rows | 4 months of data (Sep-Dec 2024)
--
-- BUSINESS QUESTION:
-- How should inventory move through a multi-echelon fulfillment
-- network to guarantee customer order fulfilment within 24 hours
-- at the lowest possible cost?
--
-- NETWORK STRUCTURE:
-- Supplier → 1DC/RDC → IXD → FC → NEXUS → Customer
--
-- SECTIONS:
--   Section 1: Network Baseline Analysis
--   Section 2: Where is the Network Failing (Stockout Analysis)
--   Section 3: Why is it Failing (Root Cause Analysis)
--   Section 4: Push vs Pull Model Comparison
-- ============================================================


-- ============================================================
-- SECTION 1: NETWORK BASELINE ANALYSIS
-- Objective: Understand current inventory distribution,
--            capacity utilisation, and cost structure
--            across all node types before identifying failures
-- ============================================================

-- ------------------------------------------------------------
-- Q1.1: Inventory Distribution and Capacity Utilisation by Node Type
-- 
-- Objective: Measure how much inventory is sitting at each node
--            type and what it costs to hold it there
--
-- Finding:   All node types operate at approximately 40% capacity
--            utilisation — the network is not exploiting the cost
--            advantages of each node type. FC is the most expensive
--            storage location per unit yet holds similar utilisation
--            to cheaper upstream nodes.
-- ------------------------------------------------------------

SELECT 
    noo.node_type,
    SUM(api.units_on_hand)                                              AS units_available,
    SUM(api.max_capacity)                                               AS total_capacity,
    CAST(
        (SUM(api.units_on_hand) / SUM(api.max_capacity)) * 100 
        AS DECIMAL(10,2)
    )                                                                   AS capacity_utilisation_pct,
    CAST(SUM(api.daily_storage_cost_eur) AS DECIMAL(10,3))              AS total_daily_holding_cost_eur,
    CAST(
        (SUM(api.daily_storage_cost_eur) / SUM(api.units_on_hand)) 
        AS DECIMAL(10,6)
    )                                                                   AS avg_holding_cost_per_unit_eur
FROM amazon_potfolio.inventory AS api
JOIN amazon_potfolio.nodes AS noo
    ON api.node_id = noo.node_id
GROUP BY noo.node_type
ORDER BY avg_holding_cost_per_unit_eur DESC;


-- ------------------------------------------------------------
-- Q1.2 & Q1.3: SKU Velocity Mix and Volume Distribution by Node Type
--
-- Objective: Understand which velocity categories (fast/medium/slow)
--            dominate each node type and whether inventory is
--            positioned correctly relative to each node's role
--
-- Finding:   Fast moving SKUs are correctly concentrated at FCs
--            closest to the customer. However medium SKUs accumulate
--            at 1DCs being treated the same as fast SKUs despite
--            lower demand frequency — creating unnecessary holding
--            cost at upstream nodes and excess downstream push.
-- ------------------------------------------------------------

WITH base AS (
    SELECT
        nd.node_type,
        SUM(CASE WHEN sk.velocity = 'fast'   THEN iv.units_on_hand ELSE 0 END) AS fast_units,
        SUM(CASE WHEN sk.velocity = 'fast'   THEN 1                ELSE 0 END) AS fast_sku_count,
        SUM(CASE WHEN sk.velocity = 'medium' THEN iv.units_on_hand ELSE 0 END) AS medium_units,
        SUM(CASE WHEN sk.velocity = 'medium' THEN 1                ELSE 0 END) AS medium_sku_count,
        SUM(CASE WHEN sk.velocity = 'slow'   THEN iv.units_on_hand ELSE 0 END) AS slow_units,
        SUM(CASE WHEN sk.velocity = 'slow'   THEN 1                ELSE 0 END) AS slow_sku_count,
        SUM(iv.max_capacity - iv.units_on_hand)                                AS unused_capacity
    FROM amazon_potfolio.inventory iv
    JOIN amazon_potfolio.skus sk
        ON iv.sku_id = sk.sku_id
    JOIN amazon_potfolio.nodes nd
        ON iv.node_id = nd.node_id
    GROUP BY nd.node_type
)
SELECT
    node_type,
    fast_units,
    medium_units,
    slow_units,
    unused_capacity,
    ROUND(fast_units   / (fast_units + medium_units + slow_units) * 100, 2) AS fast_pct,
    ROUND(medium_units / (fast_units + medium_units + slow_units) * 100, 2) AS medium_pct,
    ROUND(slow_units   / (fast_units + medium_units + slow_units) * 100, 2) AS slow_pct
FROM base
ORDER BY node_type;


-- ============================================================
-- SECTION 2: WHERE IS THE NETWORK FAILING
-- Objective: Identify stockout patterns across the network —
--            by fulfillment status, velocity, location,
--            and whether failures concentrate during
--            promotional demand periods
-- ============================================================

-- ------------------------------------------------------------
-- Q2.1a: Overall Network Stockout Rate
--
-- Objective: Establish the baseline stockout rate across
--            all customer orders in the network
--
-- Finding:   Approximately 7% of all units demanded result
--            in a stockout. This is the network-wide failure
--            rate against which all improvements are measured.
-- ------------------------------------------------------------

SELECT 
    fulfillment_status,
    SUM(units_demanded)                                         AS total_units,
    CAST(
        SUM(units_demanded) * 100.0 
        / SUM(SUM(units_demanded)) OVER ()
        AS DECIMAL(10,2)
    )                                                           AS pct_of_total_demand
FROM amazon_potfolio.orders
GROUP BY fulfillment_status;


-- ------------------------------------------------------------
-- Q2.1b: Stockout Rate by SKU Velocity
--
-- Objective: Determine whether fast, medium or slow moving
--            SKUs are disproportionately affected by stockouts
--
-- Finding:   Stockout rate is approximately equal (~6%) across
--            all velocity categories. This is a critical insight —
--            the network is NOT prioritising fast moving SKUs for
--            better stock protection despite their higher revenue
--            impact per stockout event.
-- ------------------------------------------------------------

SELECT 
    sk.velocity,
    SUM(od.units_demanded)                                      AS stockout_units,
    CAST(
        SUM(od.units_demanded) * 100.0 
        / SUM(SUM(od.units_demanded)) OVER ()
        AS DECIMAL(10,2)
    )                                                           AS pct_of_total_stockouts
FROM amazon_potfolio.orders od
JOIN amazon_potfolio.skus sk
    ON od.sku_id = sk.sku_id
WHERE od.fulfillment_status = 'stockout'
GROUP BY sk.velocity;


-- ------------------------------------------------------------
-- Q2.1c: Stockout Count by Fulfillment Center
--
-- Objective: Identify which FCs have the highest absolute
--            number of stockout events
--
-- Finding:   Stockouts are distributed across all FCs.
--            Use alongside Q2.1b to identify concentration
--            by category and velocity per FC.
-- ------------------------------------------------------------

SELECT 
    fc_node,
    COUNT(fc_node)                                              AS stockout_event_count
FROM amazon_potfolio.orders
WHERE fulfillment_status = 'stockout'
GROUP BY fc_node
ORDER BY stockout_event_count DESC;


-- ------------------------------------------------------------
-- Q2.1d: Stockout by SKU — Volume Impact
--
-- Objective: Find which specific SKUs are generating the most
--            stockout volume to prioritise remediation
-- ------------------------------------------------------------

SELECT 
    od.sku_id,
    sk.velocity,
    sk.category,
    COUNT(od.sku_id)                                            AS stockout_event_count,
    SUM(od.units_demanded)                                      AS total_units_lost
FROM amazon_potfolio.orders od
JOIN amazon_potfolio.skus sk
    ON od.sku_id = sk.sku_id
WHERE od.fulfillment_status = 'stockout'
GROUP BY od.sku_id, sk.velocity, sk.category
ORDER BY total_units_lost DESC;


-- ------------------------------------------------------------
-- Q2.1e: Promotional Period Impact on Stockout Rate
--
-- Objective: Test whether stockout rate increases during
--            known promotional demand spikes (Black Friday etc.)
--
-- Finding:   Stockout rate DOUBLES during promotional periods
--            (13% vs 7%). This proves the network is not
--            pre-positioning inventory upstream before known
--            demand events — a critical planning failure.
-- ------------------------------------------------------------

SELECT 
    is_promotional_period,
    COUNT(*)                                                    AS stockout_events,
    SUM(units_demanded)                                         AS stockout_units
FROM amazon_potfolio.orders
WHERE fulfillment_status = 'stockout'
GROUP BY is_promotional_period;


-- ============================================================
-- SECTION 3: WHY IS THE NETWORK FAILING — ROOT CAUSE ANALYSIS
-- Objective: Identify the upstream causes of downstream stockouts
--            across three dimensions:
--            (1) Supplier PO failures
--            (2) Transit SLA breaches
--            (3) IXD capacity pressure
-- ============================================================

-- ------------------------------------------------------------
-- Q3.1a: Stockout Events with and without Purchase Orders
--
-- Objective: For every stockout, determine whether a purchase
--            order was in place — distinguishing between
--            ordering failure (no PO) and timing/demand failure
--            (PO exists but stockout still occurred)
--
-- Finding:   Two distinct failure modes identified:
--            - 663 stockouts with NO PO raised (ordering failure)
--            - 490 stockouts despite PO existing (timing/demand failure)
--            This splits the problem into two separate root causes
--            requiring different solutions.
-- ------------------------------------------------------------

SELECT 
    SUM(CASE WHEN pr.po_id IS NOT NULL THEN 1 ELSE 0 END)       AS stockouts_with_po,
    ROUND(
        SUM(CASE WHEN pr.po_id IS NOT NULL THEN 1 ELSE 0 END) 
        / COUNT(*), 5
    )                                                           AS pct_with_po,
    SUM(CASE WHEN pr.po_id IS NULL THEN 1 ELSE 0 END)           AS stockouts_without_po,
    ROUND(
        SUM(CASE WHEN pr.po_id IS NULL THEN 1 ELSE 0 END) 
        / COUNT(*), 5
    )                                                           AS pct_without_po,
    COUNT(*)                                                    AS total_stockout_events
FROM amazon_potfolio.orders od
LEFT JOIN amazon_potfolio.purchase_orders pr
    ON od.sku_id = pr.sku_id
    AND od.order_date = pr.eta_date
WHERE od.fulfillment_status = 'stockout';


-- ------------------------------------------------------------
-- Q3.1b: Stockout Root Cause Breakdown by Velocity and Promo Period
--
-- Objective: Segment the two failure modes by SKU velocity
--            and promotional period to identify where each
--            failure type concentrates
--
-- Finding:   Three stockout buckets identified:
--            BUCKET 1 — Ordering failure: No PO raised
--                       Most visible in slow SKUs during promos
--            BUCKET 2 — Timing failure: PO exists but late arrival
--                       Most visible in fast SKUs non-promo period
--            BUCKET 3 — Demand spike failure: Promo overwhelms supply
--                       Fast and medium SKUs during promotional periods
-- ------------------------------------------------------------

SELECT 
    od.is_promotional_period,
    sk.velocity,
    SUM(CASE WHEN pr.po_id IS NULL     THEN 1 ELSE 0 END)       AS no_po_stockouts,
    SUM(CASE WHEN pr.po_id IS NOT NULL THEN 1 ELSE 0 END)       AS po_exists_stockouts
FROM amazon_potfolio.orders od
LEFT JOIN amazon_potfolio.purchase_orders pr
    ON pr.sku_id = od.sku_id
LEFT JOIN amazon_potfolio.skus sk
    ON sk.sku_id = od.sku_id
WHERE od.fulfillment_status = 'stockout'
GROUP BY od.is_promotional_period, sk.velocity
ORDER BY od.is_promotional_period, sk.velocity;


-- ------------------------------------------------------------
-- Q3.1c: SKU Misrouting Analysis — Inventory in System but Wrong Location
--
-- Objective: Check whether stockout SKUs were actually available
--            in the network on the same day but transferred to
--            the wrong node
--
-- Finding:   Many stockout SKUs had active transfers on the same
--            date — confirming inventory existed in the network
--            but was not correctly positioned at the FC where
--            demand occurred. This is a flow routing problem
--            not just an inventory volume problem.
-- ------------------------------------------------------------

SELECT
    od.fc_node,
    SUM(CASE WHEN od.fc_node =  tr.to_node THEN 1 ELSE 0 END)  AS correctly_routed,
    SUM(CASE WHEN od.fc_node != tr.to_node THEN 1 ELSE 0 END)  AS misrouted
FROM amazon_potfolio.orders od
JOIN amazon_potfolio.transfers tr
    ON od.sku_id    = tr.sku_id
    AND od.order_date = tr.transfer_date
WHERE od.fulfillment_status = 'stockout'
GROUP BY od.fc_node
ORDER BY misrouted DESC;


-- ------------------------------------------------------------
-- Q3.2a: Transfer Cost by Transport Mode
--
-- Objective: Compare cost components (handling, transit, storage)
--            between road and rail transport modes
--
-- Finding:   Road dominates short haul routes. Handling cost
--            is largely fixed. Transit cost is the primary
--            variable component — relevant for LCL vs FCL
--            consolidation decisions.
-- ------------------------------------------------------------

SELECT
    transfer_mode,
    COUNT(*)                                                    AS transfer_count,
    CAST(AVG(handling_cost_eur) AS DECIMAL(10,3))               AS avg_handling_cost,
    CAST(AVG(transit_cost_eur)  AS DECIMAL(10,3))               AS avg_transit_cost,
    CAST(AVG(storage_cost_eur)  AS DECIMAL(10,3))               AS avg_storage_cost,
    CAST(AVG(total_cost_eur)    AS DECIMAL(10,3))               AS avg_total_cost_per_transfer,
    CAST(SUM(total_cost_eur)    AS DECIMAL(10,2))               AS total_network_cost_eur
FROM amazon_potfolio.transfers
GROUP BY transfer_mode;


-- ------------------------------------------------------------
-- Q3.2b: SLA Breach Rate by Route
--
-- Objective: Identify which 1DC/RDC to IXD routes most frequently
--            breach the 10-hour transit time target
--
-- Finding:   SLA breaches are distributed across routes with no
--            single dominant failure point. The average actual
--            transit time is below planned — however a tail of
--            severely delayed shipments drives breach counts.
--            P95 percentile analysis recommended over averages.
-- ------------------------------------------------------------

SELECT 
    CONCAT(from_node, ' → ', to_node)                          AS route,
    COUNT(*)                                                    AS total_measurements,
    SUM(CASE WHEN sla_breached = TRUE THEN 1 ELSE 0 END)       AS breach_count,
    ROUND(
        SUM(CASE WHEN sla_breached = TRUE THEN 1 ELSE 0 END) 
        / COUNT(*) * 100, 2
    )                                                           AS breach_rate_pct
FROM amazon_potfolio.sla_performance
GROUP BY CONCAT(from_node, ' → ', to_node)
ORDER BY breach_count DESC;


-- ------------------------------------------------------------
-- Q3.2c: Most Common Delay Reasons
--
-- Objective: Identify the primary causes of SLA breaches
--            to target operational improvement efforts
--
-- Finding:   'Other' is the most frequent category — a data
--            quality gap requiring operational investigation
--            (Gemba walk recommended). Among named reasons:
--            port congestion, driver shortage, and customs hold
--            are the primary pain points.
-- ------------------------------------------------------------

SELECT 
    delay_reason,
    COUNT(delay_reason)                                         AS occurrence_count
FROM amazon_potfolio.sla_performance
WHERE delay_reason IS NOT NULL
GROUP BY delay_reason
ORDER BY occurrence_count DESC;


-- ------------------------------------------------------------
-- Q3.3: IXD Capacity Pressure — Cumulative Flow Analysis
--
-- Objective: Measure daily inbound vs outbound flow at each IXD
--            and track cumulative inventory buildup over time
--            to identify capacity pressure points
--
-- Finding:   Madrid and Paris IXDs show cumulative inbound
--            exceeding outbound — inventory is building up.
--            BCN and Berlin IXDs clear efficiently.
--            On peak days, cumulative balance exceeds stated
--            node capacity — confirming capacity breach risk.
--            A monthly replenishment cycle pattern is visible:
--            drawdown at month start, buildup mid-month,
--            clearance at month end.
-- ------------------------------------------------------------

WITH daily_flow AS (
    SELECT 
        CASE 
            WHEN LOWER(tr.from_node) LIKE 'ixd%' THEN tr.from_node
            WHEN LOWER(tr.to_node)   LIKE 'ixd%' THEN tr.to_node
            ELSE NULL
        END                                                         AS node,
        tr.transfer_date,
        SUM(CASE WHEN LOWER(tr.to_node)   LIKE 'ixd%' THEN tr.units ELSE 0 END) AS inbound,
        SUM(CASE WHEN LOWER(tr.from_node) LIKE 'ixd%' THEN tr.units ELSE 0 END) AS outbound,
        SUM(CASE WHEN LOWER(tr.from_node) LIKE 'ixd%' THEN tr.units ELSE 0 END)
        - SUM(CASE WHEN LOWER(tr.to_node) LIKE 'ixd%' THEN tr.units ELSE 0 END) AS daily_balance,
        AVG(nd.capacity_units)                                      AS node_capacity
    FROM amazon_potfolio.transfers tr
    JOIN amazon_potfolio.nodes nd
        ON tr.to_node = nd.node_id
    GROUP BY 
        CASE 
            WHEN LOWER(tr.from_node) LIKE 'ixd%' THEN tr.from_node
            WHEN LOWER(tr.to_node)   LIKE 'ixd%' THEN tr.to_node
            ELSE NULL
        END,
        tr.transfer_date
),
running_total AS (
    SELECT 
        node,
        transfer_date,
        inbound,
        outbound,
        daily_balance,
        node_capacity,
        SUM(daily_balance) OVER (
            PARTITION BY node
            ORDER BY transfer_date
        )                                                           AS cumulative_balance
    FROM daily_flow
    WHERE node IS NOT NULL
)
SELECT 
    node,
    MIN(node_capacity)                                          AS node_capacity,
    MIN(cumulative_balance)                                     AS min_cumulative_balance,
    MAX(cumulative_balance)                                     AS max_cumulative_balance,
    CAST(
        MAX(cumulative_balance) / MIN(node_capacity) * 100 
        AS DECIMAL(10,2)
    )                                                           AS peak_utilisation_pct
FROM running_total
GROUP BY node
ORDER BY peak_utilisation_pct DESC;


-- ============================================================
-- SECTION 4: PUSH VS PULL MODEL COMPARISON
-- Objective: Quantify the cost, stockout, and idle inventory
--            implications of switching from a forecast-driven
--            push model to a demand-driven pull model
--
-- Methodology: The replenishment_comparison table models every
--              replenishment event twice — once under push logic
--              (forecast triggered) and once under pull logic
--              (reorder point triggered). This enables direct
--              side-by-side comparison of outcomes for the same
--              SKU at the same FC on the same date.
--
-- Key finding: Push is more expensive AND has a higher stockout
--              rate simultaneously — it is not a trade-off.
--              Push over-orders, clogs FC storage with idle
--              inventory, and paradoxically creates stockouts
--              by reducing flexibility to respond to demand spikes.
-- ============================================================

-- ------------------------------------------------------------
-- Q4.1: Comprehensive Push vs Pull Comparison by IXD Region
--
-- Metrics compared:
--   - Total and average quantity ordered
--   - Stockout rates under each model
--   - Average idle inventory days
--   - Total and average replenishment cost
--   - Dynamic optimal cost (always choosing cheaper option)
--   - Cost savings of pull vs push
--   - Cost savings of dynamic vs push
--
-- Finding:   Push generates approximately 5x more idle inventory
--            days than pull. Pull reduces stockout rate by ~50%.
--            Pull reduces total replenishment cost consistently
--            across all IXD regions. The dynamic optimal model
--            shows additional marginal savings beyond always-pull
--            confirming pull is the dominant strategy in most
--            but not all replenishment scenarios.
-- ------------------------------------------------------------

SELECT 
    rc.ixd_node,

    -- Volume comparison
    SUM(rc.push_qty_ordered)                                    AS total_push_qty,
    SUM(rc.pull_qty_ordered)                                    AS total_pull_qty,
    CAST(AVG(rc.push_qty_ordered) AS DECIMAL(10,2))             AS avg_push_qty,
    CAST(AVG(rc.pull_qty_ordered) AS DECIMAL(10,2))             AS avg_pull_qty,

    -- Stockout rates
    ROUND(
        SUM(CASE WHEN rc.push_stockout = TRUE THEN 1 ELSE 0 END) 
        / COUNT(*) * 100, 2
    )                                                           AS push_stockout_rate_pct,
    ROUND(
        SUM(CASE WHEN rc.pull_stockout = TRUE THEN 1 ELSE 0 END) 
        / COUNT(*) * 100, 2
    )                                                           AS pull_stockout_rate_pct,

    -- Idle inventory days
    CAST(AVG(rc.push_idle_days) AS DECIMAL(10,2))               AS avg_push_idle_days,
    CAST(AVG(rc.pull_idle_days) AS DECIMAL(10,2))               AS avg_pull_idle_days,

    -- Dynamic idle (always choose minimum)
    CAST(AVG(
        CASE WHEN rc.push_idle_days >= rc.pull_idle_days 
             THEN rc.pull_idle_days ELSE rc.push_idle_days END
    ) AS DECIMAL(10,2))                                         AS avg_dynamic_idle_days,

    -- Cost comparison
    CAST(SUM(rc.push_total_cost_eur) AS DECIMAL(10,2))          AS total_push_cost_eur,
    CAST(SUM(rc.pull_total_cost_eur) AS DECIMAL(10,2))          AS total_pull_cost_eur,
    CAST(AVG(rc.push_total_cost_eur) AS DECIMAL(10,2))          AS avg_push_cost_eur,
    CAST(AVG(rc.pull_total_cost_eur) AS DECIMAL(10,2))          AS avg_pull_cost_eur,

    -- Dynamic cost (always choose minimum per event)
    CAST(SUM(
        CASE WHEN rc.push_total_cost_eur >= rc.pull_total_cost_eur 
             THEN rc.pull_total_cost_eur ELSE rc.push_total_cost_eur END
    ) AS DECIMAL(10,2))                                         AS total_dynamic_cost_eur,

    -- Cost savings
    CAST(
        SUM(rc.push_total_cost_eur) - SUM(rc.pull_total_cost_eur) 
        AS DECIMAL(10,2)
    )                                                           AS total_saving_push_to_pull_eur,

    CAST(SUM(rc.push_total_cost_eur) - SUM(
        CASE WHEN rc.push_total_cost_eur >= rc.pull_total_cost_eur 
             THEN rc.pull_total_cost_eur ELSE rc.push_total_cost_eur END
    ) AS DECIMAL(10,2))                                         AS total_saving_push_to_dynamic_eur

FROM amazon_potfolio.replenishment_comparison rc
JOIN amazon_potfolio.skus sk
    ON rc.sku_id = sk.sku_id
GROUP BY rc.ixd_node
ORDER BY total_saving_push_to_pull_eur DESC;


-- ============================================================
-- END OF ANALYSIS
--
-- SUMMARY OF KEY FINDINGS:
--
-- 1. Network operates at uniform ~40% capacity across all node
--    types — not exploiting cost differentials between nodes
--
-- 2. Stockout rate is ~7% overall, doubling to 13% during
--    promotional periods — pre-positioning not happening
--
-- 3. Two stockout failure modes identified:
--    - 663 events with no PO raised (ordering failure)
--    - 490 events despite PO existing (timing/demand failure)
--
-- 4. IXD capacity breached on peak days in Madrid and Paris
--    — RDC consolidation not recommended until resolved
--
-- 5. Push model generates 5x more idle inventory days than pull,
--    costs more, and has a higher stockout rate — it loses on
--    every dimension simultaneously
--
-- RECOMMENDATION:
-- Transition from push (forecast-driven) to pull (reorder-point
-- triggered) replenishment model, piloting at FC_BCN1 and FC_MAD1
-- where push over-ordering is most pronounced. Resolve IXD
-- capacity constraints in Madrid and Paris before scaling.
-- Implement pre-promotional inventory positioning protocol
-- minimum 2 weeks before known demand events.
-- ============================================================
