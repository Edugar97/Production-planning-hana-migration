-- Production-planning stored procedure: SQL Server to SAP HANA migration
-- Sanitized excerpts. Proprietary identifiers are masked.

-- =====================================================================
-- 1. Hardcoded date windows replaced by configured stage durations
-- =====================================================================
-- Each item's window comes from its configured stage duration,
-- with an optional month-specific override in a user-defined table
INSERT INTO #TEMP_PLANTING
SELECT ...
FROM (
    SELECT T1."ClgCode"   AS "ActivityId",
           T1."Recontact" AS "ActivityDate",
           T2."ItemCode"  AS "ItemCode",
           COALESCE(T4."U_Weeks", T3."U_Duration", 0) AS "DurationWeeks"
    FROM ACT_LOG T1
    INNER JOIN PROD_ORD T2 ON T1."DocNum" = TO_NVARCHAR(T2."DocNum")
    LEFT  JOIN ITEM T3 ON T3."ItemCode" = T2."ItemCode"
    LEFT  JOIN "@STAGE_DURATION" T4
           ON T4."U_ItemCode" = T2."ItemCode"
          AND T4."U_Month"    = MONTH(T1."Recontact")
    WHERE T2."ItemCode" LIKE '<family>%'
      AND T1."Action" = 'T'
) AS T
WHERE "ActivityDate"
      BETWEEN ADD_DAYS(CURRENT_DATE, -("DurationWeeks" * 2 * 7))
          AND ADD_DAYS(CURRENT_DATE, -("DurationWeeks" * 7));

-- =====================================================================
-- 2. Nine copy-pasted UNION ALL blocks replaced by one set-based query
-- =====================================================================
-- One set-based query replaces the nine copied blocks.
-- Fallbacks use COALESCE instead of repeated scalar subqueries.
INSERT INTO #TEMP_FACTORS
SELECT
    I."ItemCode"                                          AS "ItemCode",
    F."Rate",
    Q."YieldPct"                                          AS "Yield",
    COALESCE(F."Rate" * (Q."YieldPct" / 100), F."Rate")   AS "FinalFactor",
    I."OnHand"                                            AS "OnHand",
    I."U_DefaultFactor"                                   AS "DefaultFactor",
    COALESCE(F."StageWeeks", I."U_Duration")              AS "StageWeeks",
    S."Name"                                              AS "Stage",
    S."Code"                                              AS "StageCode"
FROM ITEM I
LEFT JOIN "@STAGE"                S ON S."Code"     = I."U_StageCode"
LEFT JOIN #TEMP_RATES            F ON F."ItemCode" = I."ItemCode"
LEFT JOIN #TEMP_YIELD_BY_PRODUCT Q ON Q."ItemCode" = I."ItemCode"
WHERE I."ItemCode" LIKE :v_clone || '%'
ORDER BY I."ItemCode";

-- =====================================================================
-- 3. Unprotected stage cascade made NULL-safe and division-safe
-- =====================================================================
-- Every step is guarded against NULLs and division by zero
SELECT IFNULL(
         ((:v_S09 / NULLIF(F9."StageWeeks", 0)) * F8."StageWeeks")
         / NULLIF(COALESCE(F8."FinalFactor", F8."DefaultFactor"), 0),
       0)
INTO v_S08
FROM #TEMP_FACTORS F8
LEFT JOIN #TEMP_FACTORS F9 ON F9."StageCode" = '09'
WHERE F8."StageCode" = '08';
-- ...same pattern down to Stage 01

-- Yield with an explicit zero check
INSERT INTO #TEMP_YIELD_BY_PRODUCT
SELECT S."ItemCode",
       CASE WHEN SUM(S."Qty") = 0 THEN 0
            ELSE ROUND(((SUM(S."Qty") - SUM(IFNULL(D."Defects", 0)))
                        / SUM(S."Qty")) * 100, 2)
       END AS "YieldPct"
FROM #TEMP_PLANTING S
LEFT JOIN (SELECT "ActivityId", SUM("Defects") AS "Defects"
           FROM #TEMP_DEFECTS GROUP BY "ActivityId") D
       ON D."ActivityId" = S."ActivityId"
GROUP BY S."ItemCode";

-- =====================================================================
-- 4. Hardcoded clone branches replaced by a single parameter
-- =====================================================================
-- One query for any clone, passed in as a parameter
CREATE PROCEDURE "SP_STAGE_PRODUCTION_PLAN" (IN v_clone NVARCHAR(10))
LANGUAGE SQLSCRIPT AS
BEGIN
  DECLARE v_12WEEKS    DECIMAL(18,2);

  SELECT CASE
           WHEN IFNULL(SUM(T2."Quantity") / 12, 0) < :MIN_FLOOR
             THEN :MIN_FLOOR
           ELSE IFNULL(SUM(T2."Quantity") / 12, 0)
         END
  INTO v_12WEEKS
  FROM SALES_ORD T1
  INNER JOIN SALES_LN T2 ON T1."DocEntry" = T2."DocEntry"
  WHERE T2."ItemCode" LIKE :v_clone || '%'
    AND RIGHT(T2."ItemCode", 1) IN ('5','6','7','9','0')
    AND T1."DocStatus" = 'O'
    AND T1."DocDueDate" BETWEEN CURRENT_DATE AND ADD_DAYS(CURRENT_DATE, 84);
  -- ...
END;

