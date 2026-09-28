# Review-bot settings

`kendex.toml` holds the review configuration. The bot-instructions package renders the root review section and the enabled native instruction files.

The review-gate package and automatic refresh workflow are not installed. Update packages manually with `kendex refresh` from the main checkout.

## Capability record

| Capability | State | Evidence or remaining check |
|---|---|---|
| Codex | Instructions enabled; reviews optional | Native instructions remain for requested reviews. No required review, review-gate workflow or branch rule blocks merging. External app automatic-review settings are not managed by this manifest. |
| Copilot | Instructions enabled; automatic ruleset removed | Native instructions remain for requested reviews. No automatic-review ruleset or required review is configured; GitHub Actions is disabled. |
| CodeRabbit | Disabled | The organization has disabled the bot. Vendor overrides, resolved configuration and integrations are unverified. |
| Qodo and its optional files | Disabled | Retirement is requested. App removal, product type, wiki settings, organization overrides and the REVIEW.md portal toggle are unverified. |
| Macroscope | Disabled | Installation, correctness mode, comment severity, automatic runs and spend limits are unverified. |

Copilot content exclusions and organization runner settings require administrator verification. Generated exclusion instructions do not prove that a vendor excludes those paths. The enabled bots have posted on the repository; instruction use after adoption still requires a review on the adoption PR.

## Schema

`coderabbit-schema.json` comes from [CodeRabbit's published schema](https://coderabbit.ai/integrations/schema.v2.json). Retrieval and JSON parsing succeeded. The disabled CodeRabbit capability renders no vendor file, so its configuration validation has no input.

Use the [installed checklist](../.agents/skills/bot-instructions/references/checklist.md) before enabling another capability. The package cannot preserve the old CodeRabbit chat restrictions, tracker integrations or tool switches through its manifest. Resolve that upstream before enabling CodeRabbit.
