# Run MiniBank on demand

Run from PowerShell 7 with the existing Azure CLI login, Terraform 1.10+, and the initialized `C:\projects\minibank\infra` backend. Run both phases from the same Windows account and machine. Plan and status do not create or remove Azure resources. Run the second command in a pair only after reviewing the plan.

Use the lifecycle script when turning SQL on or off. A regular base-stack apply uses the default baseline, which includes the SQL database.

## Commands

```powershell
Set-Location 'C:\projects\minibank'
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action Status

# SQL only
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action PlanStart -Component Sql
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action Start -Component Sql

# Developer gateway, independently of SQL
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action PlanStart -Component Mcp
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action Start -Component Mcp

# Stop the Developer gateway when the MCP experiment is over
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action PlanStop -Component Mcp
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action Stop -Component Mcp

# Stop SQL after pausing SQL write jobs and closing write sessions
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action PlanStop -Component Sql
.\scripts\Invoke-MiniBankLifecycle.ps1 -Action Stop -Component Sql -WritersStopped
```

For a new, intentionally disposable SQL database with no backup history, pass `-SeedNew` to **Start**. The script runs the deterministic seed twice, checks the payment fixture and counts, and reapplies the Function managed identity's read grants. The existing SQL server and its Entra admin, workstation firewall and Functions subnet rules stay in place. If the workstation IP changed, update the existing scoped firewall configuration before using the SQL routines.

Install [Microsoft SqlPackage](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-download) on PATH or put the portable Windows release in `%LOCALAPPDATA%\MiniBank-Lifecycle\tools\sqlpackage` before SQL stop or restore. Stop exports the schema and all tables to a BACPAC while writers are paused. SQL can contain edited fixtures or other user-created data and the export includes both. The script checks the archive structure and records its SHA-256 before applying the destroy plan. Start validates that hash, imports into the empty Basic database, compares row counts and the PAY-1042 fields captured at shutdown, and reinstates the Function identity grants. Dataverse cases remain in Power Platform. [Export prerequisites](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-export) · [Import prerequisites](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-import)

Plans, backup journals, BACPACs and MCP snapshots are kept under `%LOCALAPPDATA%\MiniBank-Lifecycle\<subscription ID>`. Protect the directory and keep an independent protected copy of the BACPAC and journal if SQL is staying off. A failed export, a checksum mismatch or an interrupted import that left objects in SQL blocks the corresponding operation. Inspect the current database and use the retained BACPAC to recover before attempting another restore. Azure also offers [deleted-database recovery](https://learn.microsoft.com/azure/azure-sql/database/recovery-using-backups) within the configured retention period. After an interrupted Terraform run, check Status, generate a fresh plan and resume. The scripts won't adopt an Azure resource missing from their state automatically.

## MCP on Developer APIM

The gateway for this subscription is `minibank-mcp-bd8c986a874d` in Central US. Its dedicated Terraform key is `minibank-mcp-bd8c986a874d.tfstate` in the existing remote backend. The Payments API on Developer calls the Consumption endpoint with the operator's delegated token. Both gateways enforce the same tenant, `Payments.Read` scope and MiniBankOps group. The original Consumption managed identity keeps its existing backend permissions. No new credentials or Function access grants are required.

1. Start SQL for live payment tests and start the Developer gateway. Terraform provisions the `payment-investigation` MCP server and binds exactly **GetPayment** and **ExplainHold** to the actual REST operation IDs. The server inherits the Developer gateway's Entra policy. Start checks that the REST route and MCP initialization return HTTP 401 without credentials. [APIM MCP management API](https://learn.microsoft.com/azure/api-management/manage-mcp-servers-rest-api)
2. Get the URL from **Status** or run `terraform -chdir=infra/mcp-gateway output -raw mcp_endpoint`. For a full test, run the following PowerShell commands with a fresh delegated **Payments.Read** access token from an approved OAuth client, signed in as a MiniBankOps operator. The test initializes MCP, lists both tools and calls both for `PAY-1030`.

```powershell
$endpoint = terraform -chdir=infra/mcp-gateway output -raw mcp_endpoint
$token = Read-Host 'MiniBank operator access token' -AsSecureString
.\scripts\Test-MiniBankMcp.ps1 -Endpoint $endpoint -AccessToken $token
```

Developer stop removes its Terraform-managed MCP server and tools. Start recreates the same server, path and tools from Terraform. **CaptureMcp** and the local archive cover any additional supported MCP servers created manually. If `payment-investigation` already exists under the Developer gateway and belongs to a manual deployment, reconcile or import it into the Developer state before planning a start. A Foundry connection that supplies only an app identity needs separate authentication work because the gateway expects delegated operator claims.

The service name, default hostname and MCP path are retained across a normal restart. DNS addresses and service-generated credentials can change. This flow uses delegated Entra tokens and never moves the Power Apps connector. If provisioning prevents reuse of the same name, check Azure's deleted services and purge status. Keep use of the gateway limited to a single lifecycle owner while performing a stop.

## Cost and availability

| Component | Central US planning rate | While stopped |
|---|---:|---|
| Developer APIM, one unit | $0.07/hour, about $51.10 at 730 hours | Its REST facade and MCP endpoint are offline. The existing Consumption gateway remains available. |
| MiniBankPayments SQL Basic | $0.161/day, about $4.90 at 730 hours | Both gateways can still authenticate. Payment lookups and guidance that require SQL are offline. |

At these rates, a four-hour session costs about $0.31 for the two fixed-price components before usage charges and provisioning time. Allow roughly 30–45 minutes for Developer APIM provisioning as a planning estimate. SQL creation and the small lab BACPAC import usually need a few minutes each. Use **Status** and the script's readiness checks before testing. [API Management pricing](https://azure.microsoft.com/pricing/details/api-management/) · [SQL Database pricing](https://azure.microsoft.com/pricing/details/azure-sql-database/single/)

The read-only export check on November 22 took 4 minutes 41 seconds for the current SQL lab. The import and Developer gateway provisioning timings are estimates until the first live cycle.

Retained resources include the Consumption APIM request meter, Flex Consumption execution meters, two lab LRS storage accounts and their versions, state storage in `common`, private policy blobs, SQL backup storage where billed, and monitoring ingestion or retention. Shared Foundry and Power Platform or Fabric tenant capacity use their own billing arrangements. The resource group and server are retained, so stopping both components does not bring the entire bill to zero.
