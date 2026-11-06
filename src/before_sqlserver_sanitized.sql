-- Production-planning stored procedure: SQL Server to SAP HANA migration
-- Sanitized excerpts. Proprietary identifiers are masked.

-- =====================================================================
-- 1. Hardcoded date windows replaced by configured stage durations
-- =====================================================================
-- One hand-tuned date window per stage, hardcoded in the WHERE clause
INSERT INTO #Activities
SELECT * FROM ( /* ...activity aggregation... */ ) T
WHERE
    -- Stage 04
    ItemCode LIKE '%04' AND ActivityDate BETWEEN DATEADD(DD, -84,  GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    -- Stages 06 to 09
    ItemCode LIKE '%06' AND ActivityDate BETWEEN DATEADD(DD, -112, GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    ItemCode LIKE '%07' AND ActivityDate BETWEEN DATEADD(DD, -112, GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    ItemCode LIKE '%08' AND ActivityDate BETWEEN DATEADD(DD, -112, GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    ItemCode LIKE '%09' AND ActivityDate BETWEEN DATEADD(DD, -112, GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    -- Stage 41: widened to 28 days because 21 returned no rows
    ItemCode LIKE '%41' AND ActivityDate BETWEEN DATEADD(DD, -56,  GETDATE()) AND DATEADD(DD, -28, GETDATE()) OR
    ItemCode LIKE '%51' AND ActivityDate BETWEEN DATEADD(DD, -140, GETDATE()) AND DATEADD(DD, -70, GETDATE()) OR
    -- Range changed by hand on a later date
    ItemCode LIKE '%61' AND ActivityDate BETWEEN DATEADD(DD, -84 /*112*/, GETDATE()) AND DATEADD(DD, -42, GETDATE()) OR
    ItemCode LIKE '%76' AND ActivityDate BETWEEN DATEADD(DD, -84,  GETDATE()) AND DATEADD(DD, -42, GETDATE())

-- =====================================================================
-- 2. Nine copy-pasted UNION ALL blocks replaced by one set-based query
-- =====================================================================
INSERT INTO #FinalFactors
SELECT * FROM (
SELECT CloneCode, CloneName, ItemGroup, StageCode, StageName, Weeks,
       CASE WHEN FactorFallback IS NULL THEN RealFactor ELSE FactorFallback END Factor,
       CASE WHEN OnHand IS NULL THEN OnHandFallback ELSE OnHand END OnHand
FROM (
    SELECT T2.CloneCode, T2.CloneName, T2.ItemGroup, T1.RealFactor, T2.StageCode, T2.StageName, T2.Weeks, T1.OnHand,
    CASE WHEN (SELECT T2.RealFactor FROM #Production T2 WHERE T2.StageCode = '01' AND CloneCode = @Clone) IS NULL
         THEN (SELECT T2.RealFactor FROM #Production T2 WHERE T2.StageCode = '01' AND CloneCode = '01') END FactorFallback,
    CASE WHEN (SELECT T2.OnHand FROM #Production T2 WHERE T2.StageCode = '01' AND CloneCode = @Clone) IS NULL
         THEN 0 END OnHandFallback
    FROM #Production T1
    FULL OUTER JOIN #StageRateBase T2
      ON T1.CloneCode = T2.CloneCode AND T1.StageCode = T2.StageCode
    WHERE T2.StageCode = '01') T1

UNION ALL
/* ...the same block copied for StageCode '02', '03', '04'... */

UNION ALL
/* Stage 05: both WHEN branches test the same condition, so the second can never run */
    CASE WHEN (SELECT ... WHERE StageCode = '05' AND CloneCode = @Clone) IS NULL THEN (SELECT ... WHERE StageCode = '04' AND CloneCode = '01')
         WHEN (SELECT ... WHERE StageCode = '05' AND CloneCode = @Clone) IS NULL THEN (SELECT ... WHERE StageCode = '05' AND CloneCode = '01')
    END FactorFallback,

/* ...copied again through StageCode '09'. Stages 08 and 09 check inventory
   against a hardcoded CloneCode = '02' instead of @Clone */
) T2 WHERE CloneCode = @Clone

-- =====================================================================
-- 3. Unprotected stage cascade made NULL-safe and division-safe
-- =====================================================================
-- Backward cascade from the last stage to the first.
-- No protection: one NULL or zero factor silently breaks every stage after it.
DECLARE @S09 FLOAT = (SELECT ((@WeeklyDemand * Weeks) / RealFactor)
                      FROM #FinalFactors WHERE StageCode = 9)
DECLARE @S08 FLOAT = (SELECT (((@S09 / (SELECT Weeks FROM #FinalFactors WHERE StageCode = 9)) * Weeks) / RealFactor)
                      FROM #FinalFactors WHERE StageCode = 8)
DECLARE @S07 FLOAT = (SELECT (((@S08 / (SELECT Weeks FROM #FinalFactors WHERE StageCode = 8)) * Weeks) / RealFactor)
                      FROM #FinalFactors WHERE StageCode = 7)
-- ...same pattern down to Stage 01

-- Yield: divides by SUM(Qty) with no zero check
INSERT INTO #Yield
SELECT ItemCode, AVG(Factor) Yield FROM (
    SELECT (((SUM(Qty) - SUM(Defects)) / SUM(Qty)) * 100) Factor, ItemCode
    FROM ( /* ... */ ) T1
    GROUP BY Qty, Defects, ItemCode) T2
GROUP BY ItemCode

-- =====================================================================
-- 4. Hardcoded clone branches replaced by a single parameter
-- =====================================================================
-- Clones hardcoded in item-code patterns:
-- adding a clone means editing the procedure
DECLARE @WeeklyPlan FLOAT =
(SELECT IIF(@Clone = '02',
    (SELECT CASE WHEN AvgQty < @MinFloor THEN @MinFloor
                 WHEN AvgQty IS NULL      THEN @MinFloor
                 ELSE AvgQty END FROM (
        SELECT SUM(T2.Quantity) / 12 AvgQty FROM SALES_ORD T1
        INNER JOIN SALES_LN T2 ON T1.DocEntry = T2.DocEntry
        WHERE T2.ItemCode LIKE '<family>02%[56790]' AND T1.DocStatus = 'O'
          AND T1.DocDueDate BETWEEN GETDATE() AND DATEADD(WW, 12, GETDATE())) T),
    -- Clone 01 branch: no NULL handling, unlike the branch above
    (SELECT CASE WHEN AvgQty < @MinFloor THEN @MinFloor
                 ELSE AvgQty END FROM (
        SELECT SUM(T2.Quantity) / 12 AvgQty FROM SALES_ORD T1
        INNER JOIN SALES_LN T2 ON T1.DocEntry = T2.DocEntry
        WHERE T2.ItemCode LIKE '<family>01%[56790]' AND T1.DocStatus = 'O'
          AND T1.DocDueDate BETWEEN GETDATE() AND DATEADD(WW, 12, GETDATE())) T)))

