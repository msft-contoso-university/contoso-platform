# contoso-platform
Reproducible Azure ADLC demo lifecycle with azd, Bicep, GitHub agents and SRE

**Not deployable yet.** The azd entrypoint is deliberately fail-closed:
`up`, `provision`, `deploy`, and `down` are blocked while private deployment,
workload infrastructure, integrations, and teardown remain incomplete.

## Locked source bootstrap

Run `pwsh -File scripts\materialize-sources.ps1` before azd evaluates service
project paths. It materializes only the four allowlisted public application
repositories at the exact commits in `sources.lock.json`, and refuses to
overwrite, switch or clean an existing checkout. If a clone fails, inspect the
named partial checkout before retrying. The current lock records initial
baselines, not an approved release: three repositories contain documentation
only, and the students main branch contains characterization tests only.

`pwsh -File scripts\materialize-sources.ps1 -ValidateOnly` checks lock structure
without network access; it does not verify release readiness or deploy anything.

## Stack inputs

`infra/main.bicepparam` binds one azd environment to the shared stack and both
stages. It requires `AZURE_ENV_NAME`, `AZURE_LOCATION`,
`ADLC_STACK_GENERATION`, `ADLC_VNET_PREFIX`, `ADLC_RUNNER_SUBNET_PREFIX`,
`ADLC_ENDPOINT_SUBNET_PREFIX`, `ADLC_APPLICATION_SUBNETS` (JSON array),
`ADLC_DEV_APP_SUBNET_NAME`, `ADLC_STAGING_APP_SUBNET_NAME`,
`ADLC_RUNNER_HTTPS_EGRESS_PREFIXES` (JSON array), `ADLC_DATABASE_SKU` (JSON
object), and `ADLC_LOG_DAILY_QUOTA_GB` (integer), plus
`ADLC_{DEV,STAGING}_{STUDENTS,ACADEMICS}_AUDIENCE`. There are no target or
region defaults. These parameters are an incomplete interface, not permission
to provision; additional inputs and validation are still required. A missing
environment variable can compile to an empty string on Windows, so a future
lifecycle preflight must reject empty values before any deployment.

## Private execution foundation (incomplete)

The shared foundation Bicep composes one VNet, a delegated ACI runner subnet,
NAT, restrictive runner NSG, private DNS zones, and a dedicated deployment-script
identity and storage account. It also composes a private Premium registry,
shared Log Analytics workspace, and separate dev/staging Application Insights
resources. A separate awaited probe checks private DNS and TCP/TLS connectivity.
The subscription-scope template composes these resources and private Students
and Academics App Services for both stages. This remains incomplete and
unvalidated in Azure; it does not deploy packages or establish runner
connectivity. Do not deploy individual modules as a substitute for the stack.

The storage account follows the documented private deployment-script path:
shared-key capability is enabled, public network access is restricted by a
deny-by-default firewall, a storage service endpoint and trusted-services
exception, and an Azure Files private endpoint. The runner identity receives
Storage File Data Privileged Contributor only on that storage account. These
requirements and their permissions must be reviewed before deployment.

The caller must validate explicit network inputs with
`python scripts\validate-network-inputs.py <network-config.json>`; this check is
not yet connected to an azd lifecycle. It rejects overlapping or non-private
VNet subnets, invalid App Service subnet delegation and unbounded runner HTTPS
egress. The HTTPS destination list must
be derived and maintained for the actual deployment and authenticated control
plane; structural validation does not establish connectivity or trust. The NSG
allows private endpoint ports 443, 445, and 1433, DNS, storage service traffic,
and those explicit HTTPS ranges, and denies other runner outbound traffic.
SQL connectivity must use a policy compatible with this port restriction.
Application Insights local authentication is disabled: workloads need managed
identity-based telemetry authentication and a scoped ingestion role. The API
hosting modules define that role per Application Insights resource, but neither
role assignment nor end-to-end telemetry has been exercised in Azure.

The SQL modules define private, Entra-only servers and one database per service.
Each environment has a separate bootstrap identity; the private grant script
assigns runtime identities read/write access and grants DDL only to distinct
migration identities. Private API hosting defines separate migration identities
and scoped execution-storage access for Students and Academics; Enrollments
identity and migration execution are not yet wired. The azd hook awaits private grant deployments and checks
both stages' ownership and inputs, but lifecycle guards prevent it from running.
SQL principal discovery permissions, migration identities, migrations, and
Azure execution itself are not yet complete. The copied SQL grant scripts must not be run directly
from an ordinary workstation against a private endpoint.

`scripts\stack-lock.py` implements an experimental GitHub-backed stack lock:
create is atomic and release checks the owner's operation ID and current blob
SHA. All generations of the same tenant/subscription/environment share a lock.
It requires a separately provisioned `adlc-state` branch and tightly scoped
write credentials, neither of which has been configured or verified. The
lifecycle does not yet invoke it. Do not clear an abandoned lock until the
owning operation is known to have stopped and the exact recovery is approved.
