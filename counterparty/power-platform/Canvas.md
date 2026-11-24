# Counterparty investigation screen

In the unmanaged **MiniBank Lab** solution, add a screen named `scrCounterparty` to **MiniBank Operator** and add the **Counterparty Requests** and **Counterparty Investigations** Dataverse data sources. Add a **Counterparty investigation** button to the existing screen with `OnSelect = Navigate(scrCounterparty, ScreenTransition.None)`. On the new screen, use three text inputs named `txtLei`, `txtLegalName`, and `txtJurisdiction`. Add a **Start investigation** button, a **Refresh result** button, and a multiline results label.

## Add the controls in Studio

1. Open **Data → Add data** and add **Counterparty Requests** and **Counterparty Investigations** from the current Dataverse environment.
2. Create a **Blank** screen and rename it `scrCounterparty`.
3. Copy the full contents of [CounterpartyControls.yaml](CounterpartyControls.yaml). In **Tree view**, right-click `scrCounterparty` and choose **Paste code**.
4. Copy [CounterpartyNavigation.yaml](CounterpartyNavigation.yaml). In **Tree view**, right-click `Screen1` and choose **Paste code**. The new button opens the investigation screen.
5. Preview the draft and create a request with either an LEI or a legal name and jurisdiction. Once the worker processes it, select **Refresh result**. Review other saved draft changes before publishing.

The formulas below can also be entered directly in the formula bar.

## Start investigation

Set the button's **OnSelect** property to the following formula. Set the app users' table permissions to create and read their request rows and read their assigned investigation rows. Assign the worker a separate connection with permission to create and update investigations.

```powerfx
If(
    (!IsBlank(Trim(txtLei.Text)) && (!IsBlank(Trim(txtLegalName.Text)) || !IsBlank(Trim(txtJurisdiction.Text)))) ||
    (IsBlank(Trim(txtLei.Text)) && (IsBlank(Trim(txtLegalName.Text)) || IsBlank(Trim(txtJurisdiction.Text)))),
    Notify("Enter an LEI, or a legal name and jurisdiction.", NotificationType.Error),
    Set(varCounterpartyResult, Blank());
    IfError(
        Set(
            varCounterpartyRequest,
            Patch(
                'Counterparty Requests',
                Defaults('Counterparty Requests'),
                {
                    'Request Name': "Counterparty investigation",
                    'Request Status': "queued",
                    'Request Input': JSON(
                        {
                            lei: Upper(Trim(txtLei.Text)),
                            name: Trim(txtLegalName.Text),
                            jurisdiction: Upper(Trim(txtJurisdiction.Text))
                        },
                        JSONFormat.Compact
                    )
                }
            )
        ),
        Notify("The investigation request could not be saved.", NotificationType.Error)
    )
)
```

## Refresh result

Set **Refresh result → OnSelect** as follows. In Studio, select the primary-ID columns using IntelliSense if their display names differ. The logical names are `mbank_counterpartyrequestid` and `mbank_counterpartyinvestigationid`.

```powerfx
Refresh('Counterparty Requests');
Refresh('Counterparty Investigations');
Set(
    varCounterpartyResult,
    LookUp(
        'Counterparty Investigations',
        'Counterparty Investigation' = varCounterpartyRequest.'Counterparty Request'
    )
)
```

The results label can use the following **Text** formula. Use a plain text label for registry values.

```powerfx
If(
    IsBlank(varCounterpartyRequest),
    "",
    If(
        IsBlank(varCounterpartyResult),
        "Request " & Text(varCounterpartyRequest.'Counterparty Request') & " is queued.",
        varCounterpartyResult.'Investigation Status' & Char(10) &
        varCounterpartyResult.'Investigation Evidence'
    )
)
```
