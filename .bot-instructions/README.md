# Review-bot settings

`kendex.toml` holds the review configuration. The bot-instructions package renders the root review section and the enabled native instruction files.

## Capability record

| Capability | State | Evidence or remaining check |
|---|---|---|
| Codex | Enabled | The application summary on [PR 227](https://github.com/vanillagreencom/vgs/pull/227) records an automatic code review triggered by PR creation. Preserve the existing security-review scope; its separate setting is unverified. |
| Copilot | Enabled | [Repository settings](https://github.com/vanillagreencom/vgs/settings/copilot/code_review) show custom review instructions On. [The active ruleset](https://github.com/vanillagreencom/vgs/rules/20341570) reviews new pushes and excludes drafts. The review effort uses the organization default. Organization policy disables approving reviews. |
| CodeRabbit | Disabled | The organization has disabled the bot. Vendor overrides, resolved configuration and integrations are unverified. |
| Qodo and its optional files | Disabled | Retirement is requested. App removal, product type, wiki settings, organization overrides and the REVIEW.md portal toggle are unverified. |
| Macroscope | Disabled | Installation, correctness mode, comment severity, automatic runs and spend limits are unverified. |

Copilot content exclusions and organization runner settings require administrator verification. Generated exclusion instructions do not prove that a vendor excludes those paths. The enabled bots have posted on the repository; instruction use after adoption still requires a review on the adoption PR.

## Schema

`coderabbit-schema.json` comes from [CodeRabbit's published schema](https://coderabbit.ai/integrations/schema.v2.json). Retrieval and JSON parsing succeeded. The disabled CodeRabbit capability renders no vendor file, so its configuration validation has no input.

Use the [installed checklist](../.agents/skills/bot-instructions/references/checklist.md) before enabling another capability. The package cannot preserve the old CodeRabbit chat restrictions, tracker integrations or tool switches through its manifest. Resolve that upstream before enabling CodeRabbit.
