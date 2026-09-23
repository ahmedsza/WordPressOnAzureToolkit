# WordPress Well-Architected Review Skill

This repository includes the `wordpress-waf-review` skill for GitHub Copilot. It converts the redacted JSON evidence produced by `Invoke-CollectWordPressPosture.ps1` into a scored Azure Well-Architected Framework review for WordPress on Azure App Service.

The skill definition is in [.github/skills/wordpress-waf-review/SKILL.md](.github/skills/wordpress-waf-review/SKILL.md).

## When to use it

Use the skill to:

- Review a WordPress on Azure App Service workload.
- Score collected evidence against the repository's WordPress checklist.
- Generate an executive summary, a complete control-by-control assessment, and an importable findings backlog.

Do not use it to deploy or modify Azure resources, manage WordPress content, author Bicep, or review non-WordPress workloads.

## Prerequisites

To review existing evidence, provide a directory containing `collection-manifest.json`. Evidence can be collected with:

```powershell
cd Review
./PSScripts/Invoke-CollectWordPressPosture.ps1 `
  -ResourceGroup <resource-group-name> `
  -Subscription <subscription-id> `
  -OutputDirectory <evidence-directory>
```

Collecting fresh evidence requires:

- PowerShell 7 or later.
- Azure CLI authenticated with `az login`.
- At least Azure `Reader`; `Monitoring Reader` and `Security Reader` improve coverage.
- The Azure resource group and subscription ID confirmed before collection.

The collector is read-only and redacts secret values.

## How to invoke the skill

Open this repository in VS Code and ask GitHub Copilot Chat to run a WordPress WAF review. The skill is selected from the intent of the request; naming it explicitly is useful but not required.

### Review existing evidence

```text
Run the wordpress-waf-review skill using evidence in Evidence/<collection-folder>.
Write the reports to Review/reports/<report-name>.
This is a production environment with an RTO of 4 hours and an RPO of 1 hour.
```

### Collect evidence and then review

```text
Assess the WordPress Azure posture for resource group <resource-group> in subscription <subscription-id>.
Collect evidence first, then write the WAF reports to Review/reports/<report-name>.
```

### Review a collector ZIP file

```text
Generate the WordPress Well-Architected review from Evidence/<collector-output>.zip.
Expand it and write the reports to Review/reports/<report-name>.
```

Include any known workload context in the prompt, especially:

- Production or non-production environment.
- Service-level objectives.
- Recovery time objective (RTO) and recovery point objective (RPO).
- Data classification.
- Accepted risks or compensating controls.

Unknown context does not block the review; the reports record it as unknown rather than making assumptions.

## Inputs and defaults

| Input | Requirement or default |
|---|---|
| Evidence | Directory containing `collection-manifest.json`, or a collector ZIP file. If omitted, provide a resource group and subscription for collection. |
| Checklist | Defaults to [Review/reviewdocs/AzureWordPressChecklist.md](Review/reviewdocs/AzureWordPressChecklist.md). |
| Output directory | Defaults to `Review/reports/<resource-group>-<yyyyMMdd>/`. |
| Workload context | Optional, but improves assessment quality and prioritization. |

## Outputs

The skill always creates these three files in the selected output directory:

| File | Purpose |
|---|---|
| `executive-summary.md` | Leadership scorecard, evidence coverage, strengths, top risks, and prioritized remediation. |
| `detailed-well-architected-review.md` | Assessment of all 157 checklist controls with status, evidence pointers, and recommendations. |
| `findings.csv` | One row for every failure or material evidence gap, scored for severity, effort, risk, and cost. |

The final Copilot response also reports the output paths, overall score and evidence coverage, critical and high finding counts, and the three most important collection gaps.

## Assessment behavior

Each applicable checklist control receives one status: `Pass`, `Fail`, `N/A`, or `Not verified`. A pass or failure requires a concrete JSON evidence pointer. Missing or failed collection sections are marked `Not verified`, and controls requiring manual validation remain `Not verified` unless dated manual evidence is supplied.

Scores are always presented with evidence coverage. The reports never reproduce secrets, keys, connection strings, or redacted secret values.

## Related documentation

- [Review/README.md](Review/README.md) explains evidence collection and collector output.
- [Review/reviewdocs/AzureWordPressChecklist.md](Review/reviewdocs/AzureWordPressChecklist.md) is the assessment checklist.
- [Review/genreport.md](Review/genreport.md) contains the original report-generation prompt reference.