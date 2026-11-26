# Bringing manually created ("ClickOps") Azure resources under Terraform

This is the playbook used when we found resources that had been created by hand
in the portal (a DNS zone, a storage account for exports, NSG rules added during
an incident) and needed to manage them as code **without recreating them**.

## 1. Inventory what exists

```bash
# Everything in a resource group, with who created it and when
az resource list -g rg-legacy-shop --query "[].{name:name,type:type,id:id}" -o table
az monitor activity-log list -g rg-legacy-shop --offset 90d \
  --query "[?operationName.value=='Microsoft.Resources/deployments/write'].{who:caller,when:eventTimestamp}"
```

Tag everything Terraform manages with `managed_by=terraform`; an Azure Resource
Graph query then lists anything *not* managed:

```kusto
resources
| where resourceGroup startswith "rg-shopsphere"
| where tags.managed_by != "terraform"
| project name, type, resourceGroup, id
```

## 2. Generate code (two options)

**a) aztfexport (fast, for whole resource groups)** — see `scripts/migrate/import-existing.sh`

```bash
aztfexport resource-group --non-interactive --hcl-only --output-dir ./generated rg-legacy-shop
```

It writes `main.tf` + `import.tf`. Treat the output as a *draft*: rename
resources, replace hard-coded IDs with references, move into modules.

**b) Native `import` blocks + config generation (precise, reviewable)**

```hcl
# imports.tf  (example file: imports.tf.example - copy it into a real stack to use)
import {
  to = azurerm_dns_zone.public
  id = "/subscriptions/<sub>/resourceGroups/rg-dns/providers/Microsoft.Network/dnsZones/example.com"
}
```

```bash
terraform plan -generate-config-out=generated.tf   # writes HCL for the imported resource
```

## 3. Iterate until the plan is empty

The import PR is only mergeable when `terraform plan` shows
`N to import, 0 to add, 0 to change, 0 to destroy`. Any "change" means the
code doesn't match reality yet — fix the code, not the resource.

## 4. Refactor safely

Use `moved` blocks when restructuring so nothing is destroyed:

```hcl
moved {
  from = azurerm_dns_zone.public
  to   = module.dns.azurerm_dns_zone.this
}
```

Use `removed` blocks to stop managing something without deleting it:

```hcl
removed {
  from = azurerm_storage_account.legacy_exports
  lifecycle { destroy = false }
}
```

## 5. Keep it from happening again

* Contributor rights removed from humans in prod; portal is read-only (Reader +
  PIM-elevated break-glass).
* Azure Policy `deny` for resources without the `managed_by` tag in prod.
* Nightly `terraform-drift.yml` opens an issue when `plan` is not empty.
