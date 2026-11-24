# Run the MiniBank counterparty investigation

The Python worker uses two named prompt agents in `proj-minibank` through Microsoft Agent Framework and the existing `gpt-4.1-mini` model. It resolves a public LEI or legal name with GLEIF. After identity confirmation, it reads accounting-consolidation evidence and searches a small RDF graph of synthetic payments. The result cites the registry record URLs and the pinned FIBO OWL version. The existing SQL ledger is outside this scenario.

## Setup and run

Use the existing Azure CLI login for Foundry. Use a separate Azure CLI profile for the Dataverse operator in MiniBank-Lab. The Dataverse setup script previews metadata changes by default. The `-Apply` switch adds the two tables to the existing unmanaged solution.

```powershell
Set-Location C:\projects\minibank
python -m venv .counterparty-venv
$python = '.\.counterparty-venv\Scripts\python.exe'
& $python -m pip install -r .\counterparty\requirements.txt
& $python -m unittest discover -s counterparty/tests -v

$env:FOUNDRY_PROJECT_ENDPOINT = 'https://shared-lab-foundry.services.ai.azure.com/api/projects/proj-minibank'
& $python -m counterparty.cli agents
& $python -m counterparty.cli agents --apply
```

Set `MINIBANK_COUNTERPARTY_AGENT_VERSIONS` to the deployed versions. Both initial versions are `1`. For live Dataverse runs, set the organization URL and entity set and acquire a short-lived Dataverse token in the separate profile. Restore the regular Azure CLI profile before invoking the worker so Foundry uses its existing credentials.

```powershell
$env:MINIBANK_COUNTERPARTY_AGENT_VERSIONS = '{"entity-research":"1","relationship-analyst":"1"}'
$env:MINIBANK_DATAVERSE_URL = 'https://orgf038e181.crm.dynamics.com'
$env:MINIBANK_DATAVERSE_ENTITY_SET = 'mbank_counterpartyinvestigations'
$priorProfile = $env:AZURE_CONFIG_DIR
try {
    $env:AZURE_CONFIG_DIR = $dataverseProfile
    $env:MINIBANK_DATAVERSE_TOKEN = az account get-access-token --tenant d5b48ebd-83f6-48f0-8910-983b68fd884a --resource $env:MINIBANK_DATAVERSE_URL --query accessToken -o tsv --only-show-errors
} finally {
    $env:AZURE_CONFIG_DIR = $priorProfile
}
try {
    & $python -m counterparty.cli start --lei 549300WCLFVEBTBNRF76
    & $python -m counterparty.cli start --name 'Microsoft Ireland' --jurisdiction IE
    & $python -m counterparty.cli worker-once
} finally {
    Remove-Item Env:MINIBANK_DATAVERSE_TOKEN -ErrorAction SilentlyContinue
}
```

`$dataverseProfile` is the path to the separate authenticated Azure CLI profile. Set `APPLICATIONINSIGHTS_CONNECTION_STRING` locally to export traces to the existing MiniBank Application Insights resource. A confirmed single-LEI run records one OpenTelemetry trace ID with each agent's Foundry response ID. Across an approval pause and resume, Dataverse preserves both sets of traces under the same investigation GUID.

## Power Platform

- [Canvas controls and Power Fx](../counterparty/power-platform/Canvas.md) for the operator entry point.
- [Teams approval flow](../counterparty/power-platform/Approval.md) for candidate selection, conditional writes and retries.
- `worker-once` reads queued requests, creates authoritative investigation rows with the same GUID and resumes confirmed states. The operator should have create/read on request rows and read access to assigned evidence rows. The trusted worker and approval connections need only the relevant read/write access on the two custom tables. For an unattended worker, provision a Dataverse application user in MiniBank-Lab and use a scoped custom security role. The existing `id-minibank-functions` identity was checked and currently has no Dataverse application user.

This adds two prompt-agent definitions and Dataverse rows using existing services. Model inference and monitoring are usage-billed. The verified local runs require no dedicated compute or new Terraform resource. Stop running the local worker when idle. The existing Developer APIM, Payments and Review Case lifecycle are independent.

## Verified live runs

| Scenario | Dataverse investigation | Observed result |
|---|---|---|
| Confirmed LEI `549300WCLFVEBTBNRF76` | `019fbbb9-3cea-4e39-b0ec-b89d9e6491a5` | Completed through both Foundry agents. `CP-SYN-0002` links to `635400JZ1NEQHQOKXP67` through their common ultimate accounting parent `INR2EJN1ERAN0W5ZP974`. Trace ID `3238bdf51eef3f53b78d305fecb8a887`. |
| `Microsoft Ireland`, jurisdiction `IE` | `019fbbba-784f-4011-9d66-6a028cca622a` | Four candidates. It paused before querying payments, then resumed after the operator selected `549300WCLFVEBTBNRF76`. Completed with `CP-SYN-0001` and `CP-SYN-0002`. Trace IDs `a459c1bea0edf0dd566c89243c16af2d` (before approval) and `c9e8bac17823e3beea66431dfb750d69` (after approval). |
| Dataverse request queue | `5182dc0b-dc25-4019-9093-aca71e7607cb` | Initial attempt stayed confirmed on a registry error. The next worker pass completed the same GUID and returned both synthetic payment IDs. |

The pause, approval binding, replay, resumed graph lookup, outage and input-isolation cases also pass the fixture tests. The Teams flow `f4fe7d7e-3ee7-f111-84ea-0022480803a8` ran successfully in MiniBank-Lab. Approval `88911d4b-ef75-4607-8862-17a9d351a625` was recorded on the saved ambiguous case before the local worker resumed that same investigation. In Power Apps Studio preview, MiniBank Operator opened the investigation screen and queued LEI `549300WCLFVEBTBNRF76` as Dataverse request `c96ac0f9-52e7-f111-84ea-0022480803a8`. After a local worker pass, **Refresh result** displayed `completed` with `CP-SYN-0001` and `CP-SYN-0002`. Both Foundry agents ran under trace `92fb59397c1e84323f481cf25c50c962`. Power Apps Studio confirmed successful publication of MiniBank Operator in MiniBank-Lab on 2026-11-23 at 10:42:40 EST. [GLEIF relationship for Operations Limited](https://api.gleif.org/api/v1/lei-records/549300WCLFVEBTBNRF76/ultimate-parent-relationship) · [GLEIF relationship for Payment Services Limited](https://api.gleif.org/api/v1/lei-records/635400JZ1NEQHQOKXP67/ultimate-parent-relationship)
