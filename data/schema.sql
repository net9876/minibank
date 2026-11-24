SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customer (
        [customerId] varchar(16) NOT NULL PRIMARY KEY,
        [alias] nvarchar(80) NOT NULL,
        [segment] nvarchar(32) NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.Account', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Account (
        [accountId] varchar(16) NOT NULL PRIMARY KEY,
        [customerId] varchar(16) NOT NULL,
        [currency] char(3) NOT NULL,
        FOREIGN KEY (customerId) REFERENCES dbo.Customer(customerId)
    );
END;

IF OBJECT_ID(N'dbo.Beneficiary', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Beneficiary (
        [beneficiaryId] varchar(16) NOT NULL PRIMARY KEY,
        [alias] nvarchar(80) NOT NULL,
        [countryCode] char(2) NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.Payment', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Payment (
        [paymentId] varchar(32) NOT NULL PRIMARY KEY,
        [accountId] varchar(16) NOT NULL,
        [beneficiaryId] varchar(16) NOT NULL,
        [amount] decimal(19,4) NOT NULL,
        [currency] char(3) NOT NULL,
        [createdUtc] datetime2(0) NOT NULL,
        [status] varchar(16) NOT NULL,
        [reasonCode] varchar(32) NULL,
        [holdReason] nvarchar(128) NULL,
        [asOfUtc] datetime2(0) NOT NULL,
        FOREIGN KEY (accountId) REFERENCES dbo.Account(accountId),
        FOREIGN KEY (beneficiaryId) REFERENCES dbo.Beneficiary(beneficiaryId),
        CHECK (amount > 0 AND createdUtc <= asOfUtc),
        CHECK ((status = 'On hold' AND reasonCode IS NOT NULL AND holdReason IS NOT NULL) OR (status IN ('Submitted','Processing','Settled') AND reasonCode IS NULL AND holdReason IS NULL))
    );
END;

IF OBJECT_ID(N'dbo.PaymentEvent', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PaymentEvent (
        [eventId] varchar(40) NOT NULL PRIMARY KEY,
        [paymentId] varchar(32) NOT NULL,
        [sequenceNo] tinyint NOT NULL,
        [eventUtc] datetime2(0) NOT NULL,
        [status] varchar(16) NOT NULL,
        [reasonCode] varchar(32) NULL,
        FOREIGN KEY (paymentId) REFERENCES dbo.Payment(paymentId),
        UNIQUE (paymentId, sequenceNo),
        CHECK (sequenceNo BETWEEN 1 AND 4),
        CHECK ((status = 'On hold' AND reasonCode IS NOT NULL) OR (status IN ('Submitted','Processing','Settled') AND reasonCode IS NULL))
    );
END;

EXEC(N'CREATE OR ALTER VIEW dbo.PaymentFacts AS SELECT
    paymentId, accountId, beneficiaryId, amount, currency, createdUtc,
    status, reasonCode, holdReason, asOfUtc
FROM dbo.Payment');

EXEC(N'CREATE OR ALTER VIEW dbo.PaymentHistory AS SELECT
    eventId, paymentId, sequenceNo, eventUtc, status, reasonCode
FROM dbo.PaymentEvent');

EXEC(N'CREATE OR ALTER VIEW dbo.DailyHoldMetrics AS
WITH bounds AS (
    SELECT CONVERT(date, MIN(createdUtc)) AS firstDay,
           CONVERT(date, MAX(asOfUtc)) AS snapshotDay, MAX(asOfUtc) AS snapshotUtc
    FROM dbo.Payment
),
digits AS (
    SELECT digit FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS source(digit)
),
days AS (
    SELECT DATEADD(day, dayIndex.daysSinceFirst, bounds.firstDay) AS dayUtc, bounds.snapshotUtc
    FROM bounds
    CROSS JOIN digits AS a CROSS JOIN digits AS b CROSS JOIN digits AS c CROSS JOIN digits AS d
    CROSS APPLY (VALUES (a.digit + 10*b.digit + 100*c.digit + 1000*d.digit)) AS dayIndex(daysSinceFirst)
    WHERE dayIndex.daysSinceFirst < DATEDIFF(day, bounds.firstDay, bounds.snapshotDay)
),
history AS (
    SELECT paymentId, eventUtc, status, reasonCode,
           LEAD(eventUtc) OVER (PARTITION BY paymentId ORDER BY sequenceNo) AS nextEventUtc
    FROM dbo.PaymentEvent
)
SELECT days.dayUtc, p.currency, h.reasonCode, COUNT_BIG(*) AS heldCount,
       SUM(p.amount) AS heldAmount, days.snapshotUtc
FROM days
JOIN history AS h ON h.eventUtc < DATEADD(day, 1, days.dayUtc)
    AND (h.nextEventUtc IS NULL OR h.nextEventUtc >= DATEADD(day, 1, days.dayUtc))
JOIN dbo.Payment AS p ON p.paymentId = h.paymentId
WHERE h.status = ''On hold''
GROUP BY days.dayUtc, p.currency, h.reasonCode, days.snapshotUtc');
