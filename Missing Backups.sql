--Script to check missing backup without relation to schedule

DECLARE @Hours INT = 48;

WITH DBs AS
(
    SELECT
        d.name,
        d.recovery_model_desc
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name NOT IN ('master','msdb','model','tempdb','distribution','ReportServerTempDB','Logging_2023','Logging_2024','Logging_2025','Logging_2026')
      AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1   -- key AG filter
),
LastBackups AS
(
    SELECT
        bs.database_name,
        bs.type, -- D/I/L
        MAX(bs.backup_finish_date) AS last_backup_finish_date
    FROM msdb.dbo.backupset bs
   
    GROUP BY bs.database_name, bs.type
),
R AS
(
    SELECT
        d.name AS database_name,
        d.recovery_model_desc,
        lbF.last_backup_finish_date AS last_full_backup,
        lbL.last_backup_finish_date AS last_log_backup,
        CASE
            WHEN lbF.last_backup_finish_date IS NULL THEN 'Missing Full Backup'
            WHEN lbF.last_backup_finish_date < DATEADD(HOUR, -@Hours, GETDATE()) THEN 'Full Backup Out of Date'
            ELSE 'OK'
        END AS full_backup_status,
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN 'N/A (Simple Recovery)'
            WHEN lbL.last_backup_finish_date IS NULL THEN 'Missing Log Backup'
            WHEN lbL.last_backup_finish_date < DATEADD(HOUR, -@Hours, GETDATE()) THEN 'Log Backup Out of Date'
            ELSE 'OK'
        END AS log_backup_status
    FROM DBs d
    LEFT JOIN LastBackups lbF
        ON d.name = lbF.database_name AND lbF.type = 'D'
    LEFT JOIN LastBackups lbL
        ON d.name = lbL.database_name AND lbL.type = 'L'
)
SELECT *
FROM R
WHERE full_backup_status <> 'OK'
   OR log_backup_status NOT IN ('OK', 'N/A (Simple Recovery)')
   
ORDER BY database_name;

--Script to check missing backup with relation to schedule

DECLARE @GraceMinutes INT = 60;      -- tolerance on top of the schedule interval
DECLARE @DefaultHours INT = 48;      -- fallback if no job/schedule is found

WITH JobSched AS
(
    SELECT
        CASE WHEN j.name LIKE '%LOG%'  THEN 'L'
             WHEN j.name LIKE '%FULL%' THEN 'D' END AS backup_type,
        CASE
            -- Daily with intra-day repeat (log backups)
            WHEN s.freq_type = 4 AND s.freq_subday_type = 4 THEN s.freq_subday_interval
            WHEN s.freq_type = 4 AND s.freq_subday_type = 8 THEN s.freq_subday_interval * 60
            WHEN s.freq_type = 4 AND s.freq_subday_type = 2 THEN 1
            WHEN s.freq_type = 4 THEN s.freq_interval * 1440                  -- every N days
            WHEN s.freq_type = 8 THEN s.freq_recurrence_factor * 10080        -- weekly (approx.)
            WHEN s.freq_type = 16 THEN s.freq_recurrence_factor * 44640       -- monthly (approx.)
        END AS interval_minutes
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
    JOIN msdb.dbo.sysschedules s     ON s.schedule_id = js.schedule_id
    WHERE j.enabled = 1
      AND s.enabled = 1
      AND j.name LIKE '%BACKUP%'
),
Expected AS
(
    SELECT backup_type, MIN(interval_minutes) AS interval_minutes   -- strictest schedule wins
    FROM JobSched
    WHERE backup_type IS NOT NULL AND interval_minutes IS NOT NULL
    GROUP BY backup_type
),
DBs AS
(
    SELECT d.name, d.recovery_model_desc
    FROM sys.databases d
    WHERE d.state_desc = 'ONLINE'
      AND d.name NOT IN ('master','msdb','model','tempdb','distribution','ReportServerTempDB',
                         'Logging_2023','Logging_2024','Logging_2025','Logging_2026')
      AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1
),
LastBackups AS
(
    SELECT bs.database_name, bs.type, MAX(bs.backup_finish_date) AS last_backup_finish_date
    FROM msdb.dbo.backupset bs
    GROUP BY bs.database_name, bs.type
),
R AS
(
    SELECT
        d.name AS database_name,
        d.recovery_model_desc,
        lbF.last_backup_finish_date AS last_full_backup,
        lbL.last_backup_finish_date AS last_log_backup,
        COALESCE(eF.interval_minutes, @DefaultHours * 60) + @GraceMinutes AS full_allowed_minutes,
        COALESCE(eL.interval_minutes, @DefaultHours * 60) + @GraceMinutes AS log_allowed_minutes,
        CASE
            WHEN lbF.last_backup_finish_date IS NULL THEN 'Missing Full Backup'
            WHEN lbF.last_backup_finish_date < DATEADD(MINUTE, -(COALESCE(eF.interval_minutes, @DefaultHours * 60) + @GraceMinutes), GETDATE())
                THEN 'Full Backup Out of Date'
            ELSE 'OK'
        END AS full_backup_status,
        CASE
            WHEN d.recovery_model_desc = 'SIMPLE' THEN 'N/A (Simple Recovery)'
            WHEN lbL.last_backup_finish_date IS NULL THEN 'Missing Log Backup'
            WHEN lbL.last_backup_finish_date < DATEADD(MINUTE, -(COALESCE(eL.interval_minutes, @DefaultHours * 60) + @GraceMinutes), GETDATE())
                THEN 'Log Backup Out of Date'
            ELSE 'OK'
        END AS log_backup_status
    FROM DBs d
    LEFT JOIN LastBackups lbF ON d.name = lbF.database_name AND lbF.type = 'D'
    LEFT JOIN LastBackups lbL ON d.name = lbL.database_name AND lbL.type = 'L'
    LEFT JOIN Expected eF ON eF.backup_type = 'D'
    LEFT JOIN Expected eL ON eL.backup_type = 'L'
)
SELECT *
FROM R
WHERE full_backup_status <> 'OK'
   OR log_backup_status NOT IN ('OK', 'N/A (Simple Recovery)')
ORDER BY database_name;