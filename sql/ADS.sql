-- =====================================================================
-- 维度一：流量与总体转化指标大盘（核心驱动力看板）
-- =====================================================================

-- 视图 1：每日大盘核心趋势（对应：双轴折线柱状图 - 观测双十二预热）
CREATE OR REPLACE VIEW ads_global_trend AS
SELECT 
    event_date AS `日期`,
    pv_total AS `总浏览量(PV)`,
    dau_total AS `日活/去重用户数(UV)`,
    pv_per_uv AS `人均浏览深度(PV/UV)`,
    (pv_total + cart_total + fav_total + buy_total) / NULLIF(dau_total, 0) AS `人均行为次数(购买强度)`
    -- buy_total AS `总购买行为数`,
    -- conversion_rate * 100 AS `整体转化率(%)`
FROM dws_global_day;

-- 视图 2：用户留存分析报表（对应：留存趋势图 ）
CREATE OR REPLACE VIEW ads_user_retention AS
SELECT 
    t1.login_date AS `活跃基准日期`,
    COUNT(DISTINCT t1.user_id) AS `当日活跃总人数`,
    -- 次日留存人数：12-03当天无法计算（因为没有12-04的数据），强制置为 NULL
    CASE 
        WHEN t1.login_date <= '2017-12-02' THEN COUNT(DISTINCT t2.user_id)
        ELSE NULL 
    END AS `次日留存人数`,
    -- 次日留存率：12-03当天置为 NULL
    CASE 
        WHEN t1.login_date <= '2017-12-02' THEN COUNT(DISTINCT t2.user_id) / COUNT(DISTINCT t1.user_id) 
        ELSE NULL 
    END AS `次日留存率(%)`,
    -- 三日留存人数：12-01至12-03都无法计算，强制置为 NULL
    CASE 
        WHEN t1.login_date <= '2017-11-30' THEN COUNT(DISTINCT t3.user_id) 
        ELSE NULL 
    END AS `三日留存人数`,
    -- 三日留存率：12-01至12-03置为 NULL
    CASE 
        WHEN t1.login_date <= '2017-11-30' THEN COUNT(DISTINCT t3.user_id) / COUNT(DISTINCT t1.user_id) 
        ELSE NULL 
    END AS `三日留存率(%)`
FROM dws_user_retention_base t1
-- 保持高效 JOIN：直接在连接条件中锁定时间偏移
LEFT JOIN dws_user_retention_base t2 
    ON t1.user_id = t2.user_id AND t2.login_date = DATE_ADD(t1.login_date, INTERVAL 1 DAY)
LEFT JOIN dws_user_retention_base t3 
    ON t1.user_id = t3.user_id AND t3.login_date = DATE_ADD(t1.login_date, INTERVAL 3 DAY)
WHERE t1.login_date <= '2017-12-03'
GROUP BY t1.login_date;

-- 视图 3：每日行为全景趋势（对应4条趋势线，还原大盘热度波动）
CREATE OR REPLACE VIEW ads_behavior_trend AS
SELECT
    event_date AS `日期`,
    pv_total AS `点击量(PV)`,
    cart_total AS `加购量(Cart)`,
    fav_total AS `收藏量(Fav)`,
    buy_total AS `购买量(Buy)`
FROM dws_global_day;

-- 视图 4：全链路漏斗流失分析（基于总行为热度口径）
CREATE OR REPLACE VIEW ads_conversion_funnel AS
SELECT
    '浏览(PV)' AS stage,
    SUM(pv_total) AS value,
    NULL AS conversion_rate
FROM dws_global_day
UNION ALL
SELECT
    '收藏/加购(Cart+Fav)' AS stage,
    SUM(cart_total + fav_total) AS value,
    SUM(cart_total + fav_total) / NULLIF(SUM(pv_total), 0) AS conversion_rate
FROM dws_global_day
UNION ALL
SELECT
    '购买(Buy)' AS stage,
    SUM(buy_total) AS value,
    SUM(buy_total) / NULLIF(SUM(pv_total), 0)  AS conversion_rate
FROM dws_global_day;

-- =====================================================================
-- 维度二：用户结构分析（人的视角）
-- =====================================================================

-- 视图 5：动态 RFM 价值分层模型
CREATE OR REPLACE VIEW ads_user_rfm_model AS
WITH rfm_metrics AS (
    SELECT 
        user_id,
        last_active_date, -- R（最近活跃时间）
        total_behavior_cnt, -- F（行为频率） 
        total_buy_cnt -- M（购买次数）
    FROM dws_user_lifecycle
),
rfm_scores AS (
    SELECT 
        user_id,
        total_buy_cnt,
        CASE WHEN DATEDIFF('2017-12-03', last_active_date) <= 1 THEN '高' ELSE '低' END AS R,
        CASE WHEN total_behavior_cnt >= (SELECT AVG(total_behavior_cnt) FROM dws_user_lifecycle) THEN '高' ELSE '低' END AS F,
        CASE WHEN total_buy_cnt >= (SELECT AVG(total_buy_cnt) FROM dws_user_lifecycle) THEN '高' ELSE '低' END AS M
    FROM rfm_metrics
),
rfm_tags AS (
    SELECT 
        user_id,
        total_buy_cnt,
        CASE 
            WHEN R='高' AND F='高' AND M='高' THEN '重要价值用户'
            WHEN R='高' AND F='低' AND M='高' THEN '重要发展用户'
            WHEN R='低' AND F='高' AND M='高' THEN '重要保持用户'
            WHEN R='低' AND F='低' AND M='高' THEN '重要挽留用户'
            WHEN R='高' AND F='高' AND M='低' THEN '一般价值用户'
            WHEN R='高' AND F='低' AND M='低' THEN '一般发展用户'
            WHEN R='低' AND F='高' AND M='低' THEN '一般保持用户'
            WHEN R='低' AND F='低' AND M='低' THEN '流失用户'
        END AS user_category
    FROM rfm_scores
)
SELECT 
    user_category AS `用户分类标签`,
    COUNT(user_id) AS `用户数`,
    SUM(total_buy_cnt) AS `总贡献购买次数`,
    SUM(total_buy_cnt) / COUNT(user_id) AS `群组人均贡献单量`
FROM rfm_tags
GROUP BY user_category;

-- 视图 6：用户来源分层（对应：存量与增量贡献堆积条形图）
CREATE OR REPLACE VIEW ads_user_source AS
WITH user_source AS (
    SELECT 
        user_id,
        total_buy_cnt,
        CASE WHEN first_active_date <= '2017-11-27' THEN '老用户(存量)' ELSE '新用户(增量)' END AS user_type
    FROM dws_user_lifecycle
)
SELECT 
    user_type AS `用户群体`,
    COUNT(user_id) AS `总人数`,
    SUM(total_buy_cnt) AS `贡献购买总量`,
    SUM(total_buy_cnt) / COUNT(user_id) AS `人均购买单量`
FROM user_source
GROUP BY user_type;


-- =====================================================================
-- 维度三：商品结构分析（商品视角）
-- =====================================================================

-- 视图 7：品类大盘贡献 Top 10 (可作高流量低转化货品排查）
CREATE OR REPLACE VIEW ads_category AS
SELECT 
    category_id AS `品类类目ID`,
    SUM(pv_cnt) AS `总浏览量`,
    SUM(buy_cnt) AS `总购买量`,
    SUM(buy_cnt) / SUM(SUM(buy_cnt)) OVER ()  AS `购买占比_BuyShare(%)`
FROM dws_category_day
GROUP BY category_id
ORDER BY `购买占比_BuyShare(%)` DESC;


-- 视图 8：商品大盘贡献 Top 10 （可爆款分析）
CREATE OR REPLACE VIEW ads_item AS
SELECT 
    item_id AS `商品ID`,
    SUM(pv_cnt) AS `总浏览量`,
    SUM(buy_cnt) AS `总购买量`,
    SUM(buy_cnt) / SUM(SUM(buy_cnt)) OVER ()  AS `购买占比_BuyShare(%)`
FROM dws_item_day
GROUP BY item_id
ORDER BY `购买占比_BuyShare(%)` DESC
LIMIT 10;

