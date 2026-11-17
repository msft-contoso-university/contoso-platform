# Azure deployment plan

> **Status:** Executing preparation; not ready for validation or deployment.

## Project and approval

Implement the approved Contoso University ADLC reference environment. The
approved design is maintained in the coordinating session's `plan.md`; this
file records deployment preparation and its actual status, not a second design.
The user approved implementation and normal short-lived demo costs. Live
deployment, destructive operations, additional licenses, and broad role grants
retain their separate gates.

## Target and requirements

- Classification: disposable nonproduction demonstration, separate dev and
  staging with stack-owned shared resources; no production provisioning.
- Tenant and subscription: selected by the user and independently checked by
  the coordinator; supply them as environment-specific inputs, not committed
  defaults. Recheck account and tenant immediately before any deployment.
- Region: not selected. Capacity, quotas, provider support and target pricing
  remain unverified. No Azure resource deployment is authorized by this file.
- Recipe: one azd environment and Bicep, with an authenticated protected
  in-network execution phase; local and CI paths use the same lifecycle.
- Components: Web, Students and Academics on App Service; Enrollments on
  Container Apps; separate service-owned SQL databases; stack-owned network,
  registry, telemetry and SRE resources.
- Security: Entra-only SQL, narrow identities and delegated authorization;
  human-gated deployment and SRE Review mode. Monitoring Contributor at
  subscription scope requires separate explicit approval.

## Preparation and validation status

- [x] Approved full design and supporting research read.
- [x] azd/Bicep selected by approved design.
- [x] Initial static source observations and contract impact selector committed
  to `msft-contoso-university/contoso-engineering`; neither is a release gate.
- [x] Baseline source lock and PowerShell materialization pass local repeat and
  dirty-check tests. These locked baselines are not a deployable release.
- [ ] Characterize the original application and define preserved contracts.
- [ ] Implement and validate the private execution bootstrap and complete
  azd lifecycle; no remote execution or resource provisioning exists yet.
- [ ] Implement workload, platform, integration and deterministic checks.
- [ ] Select region and establish resource inventory, quotas and capacity.
- [ ] Complete identity, GitHub, SRE and consent prerequisites.
- [ ] Complete preparation and set status to `Ready for Validation`.
- [ ] Run azure-validate and record evidence before azure-deploy.
- [ ] Obtain all deployment approvals, then deploy and verify.
- [ ] Exercise scoped, explicitly confirmed teardown and recreation.

## Validation proof

None yet. No deployment, resource creation, role assignment, consent, or
live lifecycle verification has been performed.
