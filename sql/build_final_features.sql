CREATE OR REPLACE TABLE `mimic-iv-build.my_dataset.final_features` AS
WITH 

icu_ranked AS (
  SELECT subject_id, hadm_id, stay_id, intime, outtime,
    ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) AS rn
  FROM `physionet-data.mimiciv_3_1_icu.icustays`
),
first_icu AS (
  SELECT
    i.subject_id, i.hadm_id, i.stay_id, i.intime, i.outtime,
    DATETIME_DIFF(DATETIME(i.intime), DATETIME(p.anchor_year, 1, 1, 0, 0, 0), YEAR) + p.anchor_age AS age,
    p.gender
  FROM icu_ranked i
  JOIN `physionet-data.mimiciv_3_1_hosp.patients` p
    ON i.subject_id = p.subject_id
  WHERE i.rn = 1
    AND (DATETIME_DIFF(DATETIME(i.intime), DATETIME(p.anchor_year, 1, 1, 0, 0, 0), YEAR) + p.anchor_age) >= 18
),
spine AS (
  SELECT
    f.subject_id,
    f.hadm_id,
    ih.stay_id,
    f.intime AS icu_intime,
    f.outtime AS icu_outtime,
    f.age,
    f.gender,
    ih.hr,
    DATETIME_SUB(ih.endtime, INTERVAL 1 HOUR) AS starttime,
    ih.endtime AS endtime
  FROM first_icu f
  JOIN `mimic-iv-build.my_dataset.icustay_hourly` ih
    ON f.stay_id = ih.stay_id
  WHERE ih.hr >= 0
),



lactate_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS lactate
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50813
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

ph_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS ph
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50820
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

hr_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(ce.valuenum) AS heart_rate
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND ce.itemid = 220045 
   AND s.starttime < ce.charttime
   AND s.endtime >= ce.charttime
  GROUP BY s.stay_id, s.hr, s.endtime
),

temp_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(
      CASE
        WHEN ce.itemid = 223762 THEN ce.valuenum
        WHEN ce.itemid = 223761 THEN (ce.valuenum - 32) * 5 / 9
        ELSE NULL
      END
    ) AS temp_c
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND s.starttime < ce.charttime
   AND s.endtime  >= ce.charttime
   AND ce.itemid IN (223761, 223762)
   AND ce.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

rr_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(ce.valuenum) AS respiratory_rate
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND s.starttime < ce.charttime
   AND s.endtime  >= ce.charttime
   AND ce.itemid IN (220210, 224690)
   AND ce.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

bp_hourly AS (
  SELECT
    s.stay_id,
    s.hr,
    s.endtime,


    AVG(IF(ce.itemid = 220179, ce.valuenum, NULL)) AS sbp_cuff,
    AVG(IF(ce.itemid = 220180, ce.valuenum, NULL)) AS dbp_cuff,
    AVG(IF(ce.itemid = 220181, ce.valuenum, NULL)) AS map_cuff,


    AVG(IF(ce.itemid = 220050, ce.valuenum, NULL)) AS sbp_arterial,
    AVG(IF(ce.itemid = 220051, ce.valuenum, NULL)) AS dbp_arterial,
    AVG(IF(ce.itemid = 220052, ce.valuenum, NULL)) AS map_arterial,

    CASE
      WHEN COUNTIF(ce.itemid IN (220050,220051,220052)) > 0
       AND COUNTIF(ce.itemid IN (220179,220180,220181)) > 0 THEN 'MIXED'
      WHEN COUNTIF(ce.itemid IN (220050,220051,220052)) > 0 THEN 'ART'
      WHEN COUNTIF(ce.itemid IN (220179,220180,220181)) > 0 THEN 'CUFF'
      ELSE 'NONE'
    END AS bp_source

  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND s.starttime < ce.charttime
   AND s.endtime  >= ce.charttime
   AND ce.itemid IN (220179,220180,220181,220050,220051,220052)
   AND ce.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

wbc_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS wbc
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.itemid IN (51300, 51301)
   AND le.valuenum IS NOT NULL
   GROUP BY s.stay_id, s.hr, s.endtime
),

ntr_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(IF(le.itemid = 51256, le.valuenum, NULL)) AS neutrophil_pct,
    AVG(IF(le.itemid = 52075, le.valuenum, NULL)) AS neutrophil_abs
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.itemid IN (51256, 52075)
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

creatinine_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS creatinine
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50912
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

bun_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS bun
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 51006 -- Urea Nitrogen (Blood) == BUN
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

spo2_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(ce.valuenum) AS spo2
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND s.starttime < ce.charttime
   AND s.endtime  >= ce.charttime
   AND ce.itemid = 220277
   AND ce.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

sao2_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS sao2
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50817  -- oxygen saturation == sao2
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

albumin_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS albumin
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50862  -- fluid blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

bilirubin_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS bilirubin
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50885  -- total bilirubin
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

crp_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS crp
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50889  -- c-reactive protein
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

sodium_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS sodium
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50983  -- sodium, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

potassium_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS potassium
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50971  -- potassium, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

chloride_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS chloride
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50902  -- chloride, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

calcium_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS calcium
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50893  -- calcium, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

magnesium_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS magnesium
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50960  -- magnesium, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

glucose_hourly AS (
  SELECT
    s.stay_id,
    s.hr,
    s.endtime,
    AVG(val) AS glucose
  FROM spine s
  LEFT JOIN (
    -- lab glucose
    SELECT hadm_id,NULL as stay_id, charttime, valuenum AS val
    FROM `physionet-data.mimiciv_3_1_hosp.labevents`
    WHERE itemid IN (50931, 50809)
      AND valuenum BETWEEN 20 AND 800

    UNION ALL

    -- ICU glucose
    SELECT NULL as hadm_id, stay_id, charttime, valuenum AS val
    FROM `physionet-data.mimiciv_3_1_icu.chartevents`
    WHERE itemid IN (220621, 226537, 225664)
      AND valuenum BETWEEN 20 AND 800
  ) g
    ON (
         (g.stay_id = s.stay_id OR g.hadm_id = s.hadm_id)
       )
   AND g.charttime > s.starttime
   AND g.charttime <= s.endtime

  GROUP BY s.stay_id, s.hr, s.endtime
),

gcs_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(dg.gcs) AS gcs_total,
    AVG(dg.gcs_eyes) AS gcs_eyes,
    AVG(dg.gcs_verbal) AS gcs_verbal,
    AVG(dg.gcs_motor) AS gcs_motor,
    MAX(dg.gcs_unable) AS gcs_unable
  FROM spine s
  LEFT JOIN `mimic-iv-build.my_dataset.gcs` dg
    ON s.stay_id = dg.stay_id
   AND dg.charttime > s.starttime
   AND dg.charttime <= s.endtime
  GROUP BY s.stay_id, s.hr, s.endtime
),

alt_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS alt
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50861   -- alt, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

ast_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS ast
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50878    -- ast, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

ptt_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS ptt
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 51275     -- ptt, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

inr_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS inr
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 51237      -- inr, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

po2_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS po2
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50821   -- po2, blood
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

fio2_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(ce.valuenum) AS fio2
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_icu.chartevents` ce
    ON ce.stay_id = s.stay_id
   AND s.starttime < ce.charttime
   AND s.endtime  >= ce.charttime
   AND ce.itemid = 223835
   AND ce.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

bicarbonate_hourly AS (
  SELECT
    s.stay_id, s.hr, s.endtime,
    AVG(le.valuenum) AS bicarbonate
  FROM spine s
  LEFT JOIN `physionet-data.mimiciv_3_1_hosp.labevents` le
    ON le.hadm_id = s.hadm_id
   AND le.itemid = 50882   -- bicarbonate
   AND s.starttime < le.charttime
   AND s.endtime  >= le.charttime
   AND le.valuenum IS NOT NULL
  GROUP BY s.stay_id, s.hr, s.endtime
),

sepsis_hourly AS (
  SELECT
    stay_id,
    CAST(sofa_time AS DATETIME) AS onset_dt
  FROM `mimic-iv-build.my_dataset.sepsis3`
  WHERE sepsis3 = TRUE
)


    
SELECT
  s.subject_id,
  s.stay_id,
  s.hadm_id,
  s.icu_intime,
  s.icu_outtime,
  s.age,
  s.gender,
  s.hr,
  s.endtime AS chart_hour, -- hour END (matches SOFA/Sepsis3 convention)

  l.lactate,
  ph.ph,
  hr.heart_rate,
  tmp.temp_c,
  rr.respiratory_rate,
  bp.sbp_cuff,
  bp.dbp_cuff,
  bp.map_cuff,
  bp.sbp_arterial,
  bp.dbp_arterial,
  bp.map_arterial,
  bp.bp_source,
  wbc.wbc,
  ntr.neutrophil_pct,
  ntr.neutrophil_abs,
  creatinine.creatinine,
  bun.bun,
  spo2.spo2,
  sao2.sao2,
  albumin.albumin,
  bilirubin.bilirubin,
  crp.crp,
  sodium.sodium,
  potassium.potassium,
  chloride.chloride,
  calcium.calcium,
  magnesium.magnesium,
  glc.glucose,

  gcs.gcs_total,
  gcs.gcs_eyes,
  gcs.gcs_verbal,
  gcs.gcs_motor,
  gcs.gcs_unable,

  alt.alt,
  ast.ast,

  ptt.ptt,
  inr.inr,

  po2.po2,
  fio2.fio2,
  bicarbonate.bicarbonate,
  
  -- Sepsis Label
  CASE
  WHEN sh.stay_id IS NOT NULL AND s.endtime >= sh.onset_dt THEN 1 
  ELSE 0
END AS sepsis3

FROM spine s
LEFT JOIN lactate_hourly l
  ON s.stay_id = l.stay_id AND s.hr = l.hr AND s.endtime = l.endtime

LEFT JOIN ph_hourly ph
  ON s.stay_id = ph.stay_id AND s.hr = ph.hr AND s.endtime = ph.endtime

LEFT JOIN hr_hourly hr
  ON s.stay_id = hr.stay_id AND s.hr = hr.hr AND s.endtime = hr.endtime

LEFT JOIN temp_hourly tmp
  ON s.stay_id = tmp.stay_id AND s.hr = tmp.hr AND s.endtime = tmp.endtime

LEFT JOIN rr_hourly rr
  ON s.stay_id = rr.stay_id AND s.hr = rr.hr AND s.endtime = rr.endtime

LEFT JOIN bp_hourly bp
  ON s.stay_id = bp.stay_id AND s.hr = bp.hr AND s.endtime = bp.endtime

LEFT JOIN wbc_hourly wbc
  ON s.stay_id = wbc.stay_id AND s.hr = wbc.hr AND s.endtime = wbc.endtime

LEFT JOIN ntr_hourly ntr
  ON s.stay_id = ntr.stay_id AND s.hr = ntr.hr AND s.endtime = ntr.endtime

LEFT JOIN creatinine_hourly creatinine
  ON s.stay_id = creatinine.stay_id AND s.hr = creatinine.hr AND s.endtime = creatinine.endtime

LEFT JOIN bun_hourly bun
  ON s.stay_id = bun.stay_id AND s.hr = bun.hr AND s.endtime = bun.endtime

LEFT JOIN spo2_hourly spo2
  ON s.stay_id = spo2.stay_id AND s.hr = spo2.hr AND s.endtime = spo2.endtime

LEFT JOIN sao2_hourly sao2
  ON s.stay_id = sao2.stay_id AND s.hr = sao2.hr AND s.endtime = sao2.endtime

LEFT JOIN albumin_hourly albumin
  ON s.stay_id = albumin.stay_id AND s.hr = albumin.hr AND s.endtime = albumin.endtime

LEFT JOIN bilirubin_hourly bilirubin
  ON s.stay_id = bilirubin.stay_id AND s.hr = bilirubin.hr AND s.endtime = bilirubin.endtime

LEFT JOIN crp_hourly crp
  ON s.stay_id = crp.stay_id AND s.hr = crp.hr AND s.endtime = crp.endtime

LEFT JOIN sodium_hourly sodium
  ON s.stay_id = sodium.stay_id AND s.hr = sodium.hr AND s.endtime = sodium.endtime

LEFT JOIN potassium_hourly potassium
  ON s.stay_id = potassium.stay_id AND s.hr = potassium.hr AND s.endtime = potassium.endtime

LEFT JOIN chloride_hourly chloride
  ON s.stay_id = chloride.stay_id AND s.hr = chloride.hr AND s.endtime = chloride.endtime

LEFT JOIN calcium_hourly calcium
  ON s.stay_id = calcium.stay_id AND s.hr = calcium.hr AND s.endtime = calcium.endtime

LEFT JOIN magnesium_hourly magnesium
  ON s.stay_id = magnesium.stay_id AND s.hr = magnesium.hr AND s.endtime = magnesium.endtime

LEFT JOIN glucose_hourly glc
  ON s.stay_id = glc.stay_id AND s.hr = glc.hr AND s.endtime = glc.endtime

LEFT JOIN gcs_hourly gcs
  ON s.stay_id = gcs.stay_id AND s.hr = gcs.hr AND s.endtime = gcs.endtime

LEFT JOIN alt_hourly alt
  ON s.stay_id = alt.stay_id AND s.hr = alt.hr AND s.endtime = alt.endtime

LEFT JOIN ast_hourly ast
  ON s.stay_id = ast.stay_id AND s.hr = ast.hr AND s.endtime = ast.endtime

LEFT JOIN ptt_hourly ptt
  ON s.stay_id = ptt.stay_id AND s.hr = ptt.hr AND s.endtime = ptt.endtime

LEFT JOIN inr_hourly inr
  ON s.stay_id = inr.stay_id AND s.hr = inr.hr AND s.endtime = inr.endtime
  
LEFT JOIN po2_hourly po2
  ON s.stay_id = po2.stay_id AND s.hr = po2.hr AND s.endtime = po2.endtime

LEFT JOIN fio2_hourly fio2
  ON s.stay_id = fio2.stay_id AND s.hr = fio2.hr AND s.endtime = fio2.endtime

LEFT JOIN bicarbonate_hourly bicarbonate
  ON s.stay_id = bicarbonate.stay_id AND s.hr = bicarbonate.hr AND s.endtime = bicarbonate.endtime

LEFT JOIN sepsis_hourly sh
  ON s.stay_id = sh.stay_id
ORDER BY s.stay_id, s.hr;
