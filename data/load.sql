SET XACT_ABORT ON;
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRANSACTION;

DECLARE @lockResult int;
EXEC @lockResult = sys.sp_getapplock
    @Resource = 'MiniBankSeed', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
IF @lockResult < 0
    THROW 50000, 'Could not acquire MiniBank seed lock.', 1;

SELECT *
INTO #Customer
FROM OPENJSON(@snapshot, 'strict $.Customer')
WITH (
    [customerId] varchar(16) 'strict $.customerId',
    [alias] nvarchar(80) 'strict $.alias',
    [segment] nvarchar(32) 'strict $.segment'
);
IF (SELECT COUNT_BIG(*) FROM #Customer) <> 100
    THROW 50001, 'Unexpected Customer staging row count.', 1;
CREATE UNIQUE CLUSTERED INDEX IX_StageKey ON #Customer ([customerId]);

SELECT *
INTO #Account
FROM OPENJSON(@snapshot, 'strict $.Account')
WITH (
    [accountId] varchar(16) 'strict $.accountId',
    [customerId] varchar(16) 'strict $.customerId',
    [currency] char(3) 'strict $.currency'
);
IF (SELECT COUNT_BIG(*) FROM #Account) <> 150
    THROW 50001, 'Unexpected Account staging row count.', 1;
CREATE UNIQUE CLUSTERED INDEX IX_StageKey ON #Account ([accountId]);

SELECT *
INTO #Beneficiary
FROM OPENJSON(@snapshot, 'strict $.Beneficiary')
WITH (
    [beneficiaryId] varchar(16) 'strict $.beneficiaryId',
    [alias] nvarchar(80) 'strict $.alias',
    [countryCode] char(2) 'strict $.countryCode'
);
IF (SELECT COUNT_BIG(*) FROM #Beneficiary) <> 60
    THROW 50001, 'Unexpected Beneficiary staging row count.', 1;
CREATE UNIQUE CLUSTERED INDEX IX_StageKey ON #Beneficiary ([beneficiaryId]);

SELECT *
INTO #Payment
FROM OPENJSON(@snapshot, 'strict $.Payment')
WITH (
    [paymentId] varchar(32) 'strict $.paymentId',
    [accountId] varchar(16) 'strict $.accountId',
    [beneficiaryId] varchar(16) 'strict $.beneficiaryId',
    [amount] decimal(19,4) 'strict $.amount',
    [currency] char(3) 'strict $.currency',
    [createdUtc] datetime2(0) 'strict $.createdUtc',
    [status] varchar(16) 'strict $.status',
    [reasonCode] varchar(32) 'lax $.reasonCode',
    [holdReason] nvarchar(128) 'lax $.holdReason',
    [asOfUtc] datetime2(0) 'strict $.asOfUtc'
);
IF (SELECT COUNT_BIG(*) FROM #Payment) <> 1000
    THROW 50001, 'Unexpected Payment staging row count.', 1;
CREATE UNIQUE CLUSTERED INDEX IX_StageKey ON #Payment ([paymentId]);

SELECT *
INTO #PaymentEvent
FROM OPENJSON(@snapshot, 'strict $.PaymentEvent')
WITH (
    [eventId] varchar(40) 'strict $.eventId',
    [paymentId] varchar(32) 'strict $.paymentId',
    [sequenceNo] tinyint 'strict $.sequenceNo',
    [eventUtc] datetime2(0) 'strict $.eventUtc',
    [status] varchar(16) 'strict $.status',
    [reasonCode] varchar(32) 'lax $.reasonCode'
);
IF (SELECT COUNT_BIG(*) FROM #PaymentEvent) NOT BETWEEN 2000 AND 4000
    THROW 50001, 'Unexpected PaymentEvent staging row count.', 1;
CREATE UNIQUE CLUSTERED INDEX IX_StageKey ON #PaymentEvent ([eventId]);

UPDATE target
SET [alias] = source.[alias],
    [segment] = source.[segment]
FROM dbo.Customer AS target
JOIN #Customer AS source ON source.[customerId] = target.[customerId]
WHERE EXISTS (
    SELECT source.[alias], source.[segment]
    EXCEPT
    SELECT target.[alias], target.[segment]
);

INSERT dbo.Customer ([customerId], [alias], [segment])
SELECT source.[customerId], source.[alias], source.[segment]
FROM #Customer AS source
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Customer AS target WHERE target.[customerId] = source.[customerId]
);

UPDATE target
SET [customerId] = source.[customerId],
    [currency] = source.[currency]
FROM dbo.Account AS target
JOIN #Account AS source ON source.[accountId] = target.[accountId]
WHERE EXISTS (
    SELECT source.[customerId], source.[currency]
    EXCEPT
    SELECT target.[customerId], target.[currency]
);

INSERT dbo.Account ([accountId], [customerId], [currency])
SELECT source.[accountId], source.[customerId], source.[currency]
FROM #Account AS source
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Account AS target WHERE target.[accountId] = source.[accountId]
);

UPDATE target
SET [alias] = source.[alias],
    [countryCode] = source.[countryCode]
FROM dbo.Beneficiary AS target
JOIN #Beneficiary AS source ON source.[beneficiaryId] = target.[beneficiaryId]
WHERE EXISTS (
    SELECT source.[alias], source.[countryCode]
    EXCEPT
    SELECT target.[alias], target.[countryCode]
);

INSERT dbo.Beneficiary ([beneficiaryId], [alias], [countryCode])
SELECT source.[beneficiaryId], source.[alias], source.[countryCode]
FROM #Beneficiary AS source
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Beneficiary AS target WHERE target.[beneficiaryId] = source.[beneficiaryId]
);

UPDATE target
SET [accountId] = source.[accountId],
    [beneficiaryId] = source.[beneficiaryId],
    [amount] = source.[amount],
    [currency] = source.[currency],
    [createdUtc] = source.[createdUtc],
    [status] = source.[status],
    [reasonCode] = source.[reasonCode],
    [holdReason] = source.[holdReason],
    [asOfUtc] = source.[asOfUtc]
FROM dbo.Payment AS target
JOIN #Payment AS source ON source.[paymentId] = target.[paymentId]
WHERE EXISTS (
    SELECT source.[accountId], source.[beneficiaryId], source.[amount], source.[currency], source.[createdUtc], source.[status], source.[reasonCode], source.[holdReason], source.[asOfUtc]
    EXCEPT
    SELECT target.[accountId], target.[beneficiaryId], target.[amount], target.[currency], target.[createdUtc], target.[status], target.[reasonCode], target.[holdReason], target.[asOfUtc]
);

INSERT dbo.Payment ([paymentId], [accountId], [beneficiaryId], [amount], [currency], [createdUtc], [status], [reasonCode], [holdReason], [asOfUtc])
SELECT source.[paymentId], source.[accountId], source.[beneficiaryId], source.[amount], source.[currency], source.[createdUtc], source.[status], source.[reasonCode], source.[holdReason], source.[asOfUtc]
FROM #Payment AS source
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.Payment AS target WHERE target.[paymentId] = source.[paymentId]
);

UPDATE target
SET [paymentId] = source.[paymentId],
    [sequenceNo] = source.[sequenceNo],
    [eventUtc] = source.[eventUtc],
    [status] = source.[status],
    [reasonCode] = source.[reasonCode]
FROM dbo.PaymentEvent AS target
JOIN #PaymentEvent AS source ON source.[eventId] = target.[eventId]
WHERE EXISTS (
    SELECT source.[paymentId], source.[sequenceNo], source.[eventUtc], source.[status], source.[reasonCode]
    EXCEPT
    SELECT target.[paymentId], target.[sequenceNo], target.[eventUtc], target.[status], target.[reasonCode]
);

INSERT dbo.PaymentEvent ([eventId], [paymentId], [sequenceNo], [eventUtc], [status], [reasonCode])
SELECT source.[eventId], source.[paymentId], source.[sequenceNo], source.[eventUtc], source.[status], source.[reasonCode]
FROM #PaymentEvent AS source
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.PaymentEvent AS target WHERE target.[eventId] = source.[eventId]
);

IF (SELECT COUNT_BIG(*) FROM dbo.Customer) <> (SELECT COUNT_BIG(*) FROM #Customer)
    OR (SELECT COUNT_BIG(*) FROM dbo.Account) <> (SELECT COUNT_BIG(*) FROM #Account)
    OR (SELECT COUNT_BIG(*) FROM dbo.Beneficiary) <> (SELECT COUNT_BIG(*) FROM #Beneficiary)
    OR (SELECT COUNT_BIG(*) FROM dbo.Payment) <> (SELECT COUNT_BIG(*) FROM #Payment)
    OR (SELECT COUNT_BIG(*) FROM dbo.PaymentEvent) <> (SELECT COUNT_BIG(*) FROM #PaymentEvent)
    THROW 50006, 'The target contains rows outside the expected snapshot.', 1;

IF EXISTS (
    SELECT p.paymentId
    FROM dbo.Payment AS p
    LEFT JOIN dbo.PaymentEvent AS e ON e.paymentId = p.paymentId
    GROUP BY p.paymentId
    HAVING COUNT(e.eventId) NOT BETWEEN 2 AND 4
        OR MIN(e.sequenceNo) <> 1 OR MAX(e.sequenceNo) <> COUNT(e.eventId)
)
    THROW 50002, 'Invalid payment event sequence.', 1;

IF EXISTS (
    SELECT 1
    FROM dbo.Payment AS p
    CROSS APPLY (
        SELECT TOP (1) status, reasonCode, eventUtc FROM dbo.PaymentEvent AS e
        WHERE e.paymentId = p.paymentId ORDER BY e.sequenceNo DESC
    ) AS lastEvent
    WHERE lastEvent.eventUtc > p.asOfUtc OR EXISTS (
        SELECT p.status, p.reasonCode
        EXCEPT SELECT lastEvent.status, lastEvent.reasonCode
    )
)
    THROW 50003, 'Payment does not match its last event.', 1;

IF NOT EXISTS (
    SELECT 1 FROM dbo.Payment
    WHERE paymentId = 'PAY-1042' AND amount = 250.0000 AND currency = 'USD'
        AND status = 'On hold' AND reasonCode = 'BEN_VERIFICATION'
        AND holdReason = N'Beneficiary details pending verification'
)
    THROW 50004, 'Control payment does not match the documented fixture.', 1;

IF NOT EXISTS (
    SELECT 1 FROM dbo.Payment AS firstPayment
    JOIN dbo.Payment AS secondPayment ON secondPayment.beneficiaryId = firstPayment.beneficiaryId
    JOIN dbo.Account AS firstAccount ON firstAccount.accountId = firstPayment.accountId
    JOIN dbo.Account AS secondAccount ON secondAccount.accountId = secondPayment.accountId
    WHERE firstPayment.paymentId = 'PAY-1042' AND secondPayment.paymentId = 'PAY-1043'
        AND firstAccount.customerId = secondAccount.customerId
        AND firstAccount.accountId <> secondAccount.accountId
        AND firstPayment.status = 'On hold' AND secondPayment.status = 'On hold'
)
    THROW 50005, 'Analytics fixture does not match.', 1;

COMMIT TRANSACTION;

SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Customer) AS Customer,
    (SELECT COUNT_BIG(*) FROM dbo.Account) AS Account,
    (SELECT COUNT_BIG(*) FROM dbo.Beneficiary) AS Beneficiary,
    (SELECT COUNT_BIG(*) FROM dbo.Payment) AS Payment,
    (SELECT COUNT_BIG(*) FROM dbo.PaymentEvent) AS PaymentEvent;

SELECT SUM(heldCount) AS heldCount, SUM(heldAmount) AS heldAmount
FROM dbo.DailyHoldMetrics
WHERE dayUtc = CONVERT(date, '2026-11-19', 23) AND currency = 'USD';
