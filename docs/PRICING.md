# Pricing and calculation

Token Bar reports API-equivalent estimates.
It does not report subscription invoices or provider-issued token allowances.

## Price catalog

Token Bar resolves model prices in this order:

1. [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
2. [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
3. [LiteLLM model price catalog](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)

Official rows override fallback rows.
The app checks at most once every 24 hours and refreshes sooner when logs contain a missing model.
Each source keeps its own ETag, retry time, and last-known-good rows.

Unknown models stay unpriced.
Token Bar extrapolates a period's priced mix only when known prices cover at least 99.9% of its local sample.

## Token categories

The local ledgers preserve input, 5-minute cache write, 1-hour cache write, cache read, output, and reasoning tokens.

```text
model cost =
  input × input rate
  + cache writes × matching cache-write rates
  + cache reads × cache-read rate
  + output × output rate
  + reasoning excluded from the preceding output count × output rate
```

The Codex parser avoids charging reasoning twice when output already includes it.
Older Claude records without cache duration use the standard cache-write rate for the unsplit remainder.

## Calendar periods

Token Bar groups records with the current macOS calendar and time zone.
Each period uses only the model and category mix observed inside that interval.

```text
period USD per token = sampled period cost / sampled period tokens
provider period cost = provider period tokens × period USD per token
All period cost = Claude period cost + Codex period cost
```

Claude token totals and price mix come from the same local records.
Codex token totals come from the account response, while the price mix comes from same-period Codex records on this Mac.
The app hides dollars when a usable same-period mix is absent.

## Weekly capacity

```text
current implied capacity = observed tokens × 100 / official weekly percent
weekly value = estimated weekly capacity × current-window USD per token
```

Current-window observations become eligible at 3% used.
Earlier windows with at least 10% usage can supply same-source priors.
Token Bar retains 12 samples for 70 days, removes large median-absolute-deviation outliers, and blends the robust prior with the current observation in log space.
Observations from the same quota bucket and source with start and reset times less than two seconds apart count as one window, retaining its latest sample, including when loading older history.
When the account counter has not increased in a new window, a prior capacity can still be priced using the current local model mix, so the dollar projection can change before a current account sample is available.

Claude uses available local records inside the official 7-day interval.
Another computer can raise the Claude percentage without adding records on this Mac.

Codex uses:

```text
current lifetimeTokens - recorded near-start lifetimeTokens
```

The difference can include another computer on the same account.
Until Token Bar accepts an account baseline, it uses the available local Codex 7-day ledger as a fallback.
Account-wide and local-only samples keep separate histories.

## ImageGen output estimates

Token Bar estimates saved PNG outputs under `$CODEX_HOME/generated_images` or `~/.codex/generated_images`.
It assumes GPT Image 2 medium quality, using saved dimensions and file time as proxies for request size and time.
The [official calculator](https://developers.openai.com/api/docs/guides/image-generation#cost-and-latency) supplies the output-token formula; the bundled rate is [$30 per million output tokens](https://developers.openai.com/api/docs/models/gpt-image-2).
See [the implementation](../Sources/TokenBar/ImageGenerationUsage.swift) for the calculation.

```text
period cost = original estimate + image output estimate
weekly value = original estimate + image window cost × 100 / weekly percent
```

Image estimates add dollars without changing displayed token counts, quota percentages or history smoothing.
Each generation ID counts once; cached records survive removal of the source PNG.
The estimate excludes prompt/reference inputs, partial-image charges and missing outputs, including other hosts.
Account summaries do not establish whether the image addition overlaps the account token estimate.
Hover over an amount to see the image estimate and assumptions.

## Combined percentage

Claude and Codex can have different weekly capacities, so Token Bar uses a weighted result:

```text
All percent =
  sum(provider capacity × provider weekly percent)
  / sum(provider capacity)
```

All is an app-defined weighted estimate, not a provider-issued shared quota.
All remains unavailable until both providers have usable capacity evidence.

## Limits

- Current standard prices apply to retained history rather than reconstructing old price changes.
- The OpenAI catalog uses short-context Standard rates, without per-request historical, service-tier or long-context pricing.
- Account counters, local records and quota percentages may differ in scope and update timing; the near-start baseline can omit initial usage.
- Applying a local price mix to account totals assumes representative models and token categories, with matching calendar dates.
- Completed local scans do not establish whole-account coverage; Codex scans `sessions`, not archives or other hosts.
- Preserved estimates can outlive their quota state; a falling projection alone does not prove a quota reduction or poor image value.
- Claude cleanup can remove old local sessions.
- Remote Codex usage lacks a remote model and category breakdown.
- Internal model labels without a documented price remain unpriced.

Claude records deduplicate by `message.id + requestId` when both fields exist.
Codex records prefer `last_token_usage`, fall back to cumulative deltas, reject repeated totals, and suppress copied history at the start of forked sessions.

Official prices determine rates, not account coverage or prediction accuracy.
