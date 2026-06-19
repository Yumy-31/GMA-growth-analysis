# 建立ODS层
# 1、建表（统一使用 time_stamp 确保字段一致）
CREATE TABLE ods_user_behavior_log (
    user_id BIGINT,
    item_id BIGINT,
    category_id BIGINT,
    behavior_type VARCHAR(10),
    time_stamp BIGINT
);
# 2、极速导入数据
SET GLOBAL local_infile = 1;
LOAD DATA LOCAL INFILE 'D:/projects/1.taobao/data/UserBehavior.csv' 
INTO TABLE ods_user_behavior_log
FIELDS TERMINATED BY ',' 
LINES TERMINATED BY '\n' 
(user_id, item_id, category_id, behavior_type, time_stamp);
# 3、检查导入总数（应该在 1 亿条左右）
SELECT COUNT(*) FROM ods_user_behavior_log;
# 4、关闭本地文件导入功能（安全合规）
SET GLOBAL local_infile = 0;

# 建立DWD层
# 1、建表
CREATE TABLE dwd_user_behavior_detail (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT,
    item_id BIGINT,
    category_id BIGINT,
    behavior_type VARCHAR(10),
    event_time DATETIME,
    event_date DATE,
    event_hour INT,
    is_pv TINYINT,
    is_cart TINYINT,
    is_fav TINYINT,
    is_buy TINYINT
);
# 2、从 ODS 抽取连续前 1,048,562 条数据写入 DWD
INSERT INTO dwd_user_behavior_detail
(
    user_id,
    item_id,
    category_id,
    behavior_type,
    event_time,
    event_date,
    event_hour,
    is_pv,
    is_cart,
    is_fav,
    is_buy
)
SELECT
    user_id,
    item_id,
    category_id,
    behavior_type,
    -- 转换时间
    FROM_UNIXTIME(time_stamp) AS event_time,
    DATE(FROM_UNIXTIME(time_stamp)) AS event_date,
    HOUR(FROM_UNIXTIME(time_stamp)) AS event_hour,
    -- 标签化（one-hot 编码，方便后续计算各行为的总次数）
    CASE WHEN behavior_type = 'pv' THEN 1 ELSE 0 END AS is_pv,
    CASE WHEN behavior_type = 'cart' THEN 1 ELSE 0 END AS is_cart,
    CASE WHEN behavior_type = 'fav' THEN 1 ELSE 0 END AS is_fav,
    CASE WHEN behavior_type = 'buy' THEN 1 ELSE 0 END AS is_buy
FROM (
    -- 抽样优化：利用子查询先截取前 1,048,562 条连续数据，不打乱原本的用户聚拢结构
    SELECT * FROM ods_user_behavior_log 
    LIMIT 1048562
) t
WHERE 
    -- 1. 高效过滤：非空清洗
    t.user_id IS NOT NULL
    AND t.item_id IS NOT NULL
    AND t.category_id IS NOT NULL
    AND t.behavior_type IS NOT NULL
    -- 2. 时间范围清洗：剔除由于异常导致不在规定时间范围内的数据
    AND t.time_stamp BETWEEN 1511539200 AND 1512316799
-- 3. 高效去重：用 GROUP BY 替代 ROW_NUMBER()，防止内存溢出
GROUP BY t.user_id, t.item_id, t.category_id, t.behavior_type, t.time_stamp;


# 建立DWS层 （各汇总表）
# 1、用户日汇总表（粒度：每个用户每天一条数据）
DROP TABLE IF EXISTS dws_user_day;
CREATE TABLE dws_user_day (
    user_id BIGINT COMMENT '用户ID',
    event_date DATE COMMENT '日期',
    pv_cnt INT COMMENT '点击次数',
    cart_cnt INT COMMENT '加购次数',
    fav_cnt INT COMMENT '收藏次数',
    buy_cnt INT COMMENT '消费次数(消费强度)',
    behavior_cnt INT COMMENT '总行为总次数(行为强度)'
);
INSERT INTO dws_user_day
SELECT
    user_id,
    event_date,
    SUM(is_pv) AS pv_cnt,
    SUM(is_cart) AS cart_cnt,
    SUM(is_fav) AS fav_cnt,
    SUM(is_buy) AS buy_cnt,
    COUNT(*) AS behavior_cnt -- 或者写成 SUM(is_pv)+SUM(is_cart)+SUM(is_fav)+SUM(is_buy)
FROM dwd_user_behavior_detail
GROUP BY user_id, event_date;

# 2、全局日指标表（粒度：每天一条数据，用于流量与大盘转化率分析）
DROP TABLE IF EXISTS dws_global_day;
CREATE TABLE dws_global_day (
    event_date DATE COMMENT '日期',
    pv_total BIGINT COMMENT '大盘总PV',
    dau_total BIGINT COMMENT '大盘日活(DAU/UV)', -- 这里统计时间段为1day，则DAU=UV
    cart_total BIGINT COMMENT '大盘总加购量', 
    fav_total BIGINT COMMENT '大盘总收藏量',
    buy_total BIGINT COMMENT '大盘总购买量',
    pv_per_uv DOUBLE COMMENT '人均浏览量(PV/UV)',
    conversion_rate DOUBLE COMMENT '总转化率(Buy/PV)'
);
INSERT INTO dws_global_day
SELECT
    event_date,
    SUM(is_pv) AS pv_total,
    COUNT(DISTINCT user_id) AS dau_total,
    SUM(is_cart) AS cart_total, 
    SUM(is_fav) AS fav_total,
    SUM(is_buy) AS buy_total,
    -- 算人均浏览量，防止分母为0
    SUM(is_pv) / NULLIF(COUNT(DISTINCT user_id), 0) AS pv_per_uv,
    -- 算整体购买转化率
    SUM(is_buy) / NULLIF(SUM(is_pv), 0) AS conversion_rate
FROM dwd_user_behavior_detail
GROUP BY event_date;


# 3、商品日汇总表（粒度：每个商品每天一条数据，用于爆款分析）
DROP TABLE IF EXISTS dws_item_day;
CREATE TABLE dws_item_day (
    item_id BIGINT COMMENT '商品ID',
    event_date DATE COMMENT '日期',
    pv_cnt INT COMMENT '商品被浏览次数',
    buy_cnt INT COMMENT '商品被购买次数',
    item_conversion_rate DOUBLE COMMENT '商品转化率'
);
INSERT INTO dws_item_day
SELECT
    item_id,
    event_date,
    SUM(is_pv) AS pv_cnt,
    SUM(is_buy) AS buy_cnt,
    SUM(is_buy) / NULLIF(SUM(is_pv), 0) AS item_conversion_rate
FROM dwd_user_behavior_detail
GROUP BY item_id, event_date;


# 4、类目日汇总表（粒度：每个类目每天一条数据，用于行业大盘分析）
DROP TABLE IF EXISTS dws_category_day;
CREATE TABLE dws_category_day (
    category_id BIGINT COMMENT '类目ID',
    event_date DATE COMMENT '日期',
    pv_cnt INT COMMENT '类目被浏览次数',
    buy_cnt INT COMMENT '类目被购买次数',
    category_conversion_rate DOUBLE COMMENT '类目转化率'
);
INSERT INTO dws_category_day
SELECT
    category_id,
    event_date,
    SUM(is_pv) AS pv_cnt,
    SUM(is_buy) AS buy_cnt,
    SUM(is_buy) / NULLIF(SUM(is_pv), 0) AS category_conversion_rate
FROM dwd_user_behavior_detail
GROUP BY category_id, event_date;


# 5、时间维度分析表（粒度：每天每小时一条数据，用于用户活跃时间漏斗、时段消费特征分析）
DROP TABLE IF EXISTS dws_hour_day;
CREATE TABLE dws_hour_day (
    event_date DATE COMMENT '日期',
    event_hour INT COMMENT '小时(0-23)',
    pv_cnt INT COMMENT '浏览次数',
    fav_cart_cnt INT COMMENT '收藏+加购次数',
    buy_cnt INT COMMENT '购买次数'
);
INSERT INTO dws_hour_day
SELECT
    event_date,
    event_hour,
    SUM(is_pv) AS pv_cnt,
    SUM(is_fav) + SUM(is_cart) AS fav_cart_cnt,
    SUM(is_buy) AS buy_cnt
FROM dwd_user_behavior_detail
GROUP BY event_date, event_hour;

# 6、用户生命周期全局汇总表（算RFM与新老用户特征）
DROP TABLE IF EXISTS dws_user_lifecycle;
CREATE TABLE dws_user_lifecycle (
    user_id BIGINT,
    first_active_date DATE COMMENT '首次活跃日期(判定新老)',
    last_active_date DATE COMMENT '最后一次活跃日期(算R)',
    total_behavior_cnt INT COMMENT '总行为频次(算F)',
    total_buy_cnt INT COMMENT '总购买次数(算M)'
);
INSERT INTO dws_user_lifecycle
SELECT 
    user_id,
    MIN(event_date) AS first_active_date,
    MAX(event_date) AS last_active_date,
    SUM(behavior_cnt) AS total_behavior_cnt,
    SUM(buy_cnt) AS total_buy_cnt
FROM dws_user_day
GROUP BY user_id;

# 7、留存分析专用活跃对照表
DROP TABLE IF EXISTS dws_user_retention_base;
CREATE TABLE dws_user_retention_base (
  user_id BIGINT, 
  login_date DATE
);
INSERT INTO dws_user_retention_base
SELECT 
  user_id, 
  event_date 
FROM dws_user_day 
GROUP BY user_id, event_date;
