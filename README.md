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
`ADLC_DEV_CONTAINER_SUBNET_NAME`, `ADLC_STAGING_CONTAINER_SUBNET_NAME`,
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
The same template provisions internal Container Apps environments and records
their platform-managed infrastructure group names. A separate release module
requires an existing private-registry image digest, avoiding a first-deployment
dependency cycle. The protected build/push/release orchestration is not yet
implemented, and teardown must account for the platform-managed groups.

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
is intended to assign runtime identities read/write access and grant DDL only to distinct
migration identities. Each service has a separate migration identity and
scoped execution-storage access; migration execution is not yet wired. The
blocked grant hook verifies ownership, runtime-identity attachments, and the
internal Enrollments environment for both stages. It needs the Enrollments app
IDs from the later image-release phase; that release and the required hook
reordering are not yet implemented. It is additionally blocked because the
copied Azure grant script does not verify an existing database principal's SID
against the managed identity client ID. Its proposed replacement generates a
transactional, exact-client-ID SID check and grants; it has only been unit-tested,
not executed against Azure SQL. Both the private runner and hook remain blocked,
and lifecycle guards independently prevent execution. The copied scripts are
retained for reference, not used by the proposed replacement.
SQL principal discovery permissions, migration identities, migrations, and
Azure execution itself are not yet complete. The copied SQL grant scripts must not be run directly
from an ordinary workstation against a private endpoint.

`scripts\verify-candidate.py` checks a Web, Students, or Academics candidate
ZIP against an independently supplied source commit and approved SHA-256,
including its embedded manifest and every file hash, without extraction. It
does not determine approval, retrieve artifacts, deploy, or prove provenance.
It is not yet integrated into the private transport or release lifecycle.

`scripts\stack-lock.py` implements an experimental GitHub-backed stack lock:
create is atomic and release checks the owner's operation ID and current blob
SHA. All generations of the same tenant/subscription/environment share a lock.
It requires a separately provisioned `adlc-state` branch and tightly scoped
write credentials, neither of which has been configured or verified. The
lifecycle does not yet invoke it. Do not clear an abandoned lock until the
owning operation is known to have stopped and the exact recovery is approved.
`scripts\run-locked-azd.py` is a disabled prototype: its tested core passes a
fresh operation ID only to the child process and retains the lock on failure.
It cannot run via its CLI, does not integrate hook verification, and blocks
destroy entirely. It does not satisfy the required direct `azd up` and
confirmed `azd down` lifecycle.
