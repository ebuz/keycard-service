-- IMPORT EVENTS FROM EVENT FILES

.import /tmp/ubcs-423195692.events raw
.import /tmp/ubcs-423195744.events raw
.import /tmp/ubcs-423195750.events raw

INSERT OR IGNORE INTO events 
       SELECT TRIM(SUBSTR(event,1,11))  AS deviceID,
              TRIM(SUBSTR(event,12,7))  AS eventID,
              TRIM(SUBSTR(event,19,20)) AS timestamp,
              TRIM(SUBSTR(event,39,13)) AS card,
              TRIM(SUBSTR(event,52,2))  AS doorID,
              UPPER(TRIM(SUBSTR(event,54,6))) = 'TRUE' AS granted,
              TRIM(SUBSTR(event,60,4))  AS result
              FROM raw;

DELETE FROM raw;

-- TRUNCATE EVENT FILES

.once /tmp/ubcs-423195692.events
SELECT * FROM events WHERE FALSE;

.once /tmp/ubcs-423195744.events
SELECT * FROM events WHERE FALSE;

.once /tmp/ubcs-423195750.events
SELECT * FROM events WHERE FALSE;

-- PRUNE EVENTS OLDER THAN 5 YEARS

DELETE FROM events WHERE timestamp < DATE('NOW','start of month','-60 month');

-- GENERATE EVENT REPORT

.headers on
.mode tabs
.once /tmp/events.tsv

SELECT p.day             AS Date,
       IFNULL(Total,0)   AS Total,
       IFNULL(Granted,0) As Granted,
       IFNULL(Denied,0)  AS Denied FROM
       ( SELECT DATE(timestamp) AS day,COUNT(*) AS Total
                FROM events
                GROUP BY day
       ) AS p
       LEFT JOIN ( SELECT DATE(timestamp) AS day,COUNT(*) AS Granted
                          FROM events
                          WHERE granted=1
                          GROUP BY day
                 ) AS q
       ON p.day=q.day
       LEFT JOIN ( SELECT DATE(timestamp) AS day,COUNT(*) AS Denied
                          FROM events
                          WHERE granted=0
                          GROUP BY day
                 ) AS r
       ON p.day=r.day
       WHERE p.day > DATE('NOW','start of month','-18 month')
       ORDER BY Date;

-- GENERATE DENIED REPORT

.headers on
.mode tabs
.once /tmp/denied.tsv

SELECT events.timestamp AS 'Date', 
       events.card      AS 'Card Number', 
       doors.door       AS 'Door'
       FROM events
       LEFT JOIN doors ON events.deviceID=doors.deviceID AND events.doorID=doors.doorID
       WHERE granted=FALSE
         AND timestamp > DATE('NOW','-14 days')
       ORDER BY timestamp, card;

