# Pricing and calculation

Token Bar reports API-equivalent estimates.
It does not report subscription invoices or provider-issued token allowances.

## Price catalog

Token Bar resolves model prices in this order:

1. [OpenAI API pricing](https://developers.openai.com/api/docs/pricing)
2. [Claude API pricing](https://platform.claude.com/docs/en/about-claude/pricing)
3. [LiteLLM model price catalog](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)

Official rows override fallback rows.
The app checks official sources at most once every 24 hours and refreshes sooner when logs contain a missing model.
The fallback catalog is requested only for models missing from both official sources, at most weekly.
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
Codex input includes cache reads and writes, so both are subtracted before pricing ordinary input; Claude input excludes them.

Recorded Fast and Ultrafast requests use the provider's published rows for that speed, not a fixed multiplier.
Claude's fast table lists input and output only, so its cache rates scale with the fast input rate.
Codex requests over 272,000 input tokens use the official long-context columns when available.
A recorded speed without a published rate stays unpriced, and unrecorded speeds cannot be inferred from token counts.

## Calendar periods

Token Bar groups records with the current macOS calendar and time zone.
Each period uses only the model and category mix observed inside that interval.

```text
period USD per token = sampled period cost / sampled period tokens
provider period cost = provider period tokens × period USD per token
All period cost = Claude period cost + Codex period cost
```

Claude token totals and price mix come from the same local records.
Codex token totals sum each signed-in account's daily buckets, which cover every device and report UTC days.
Each bucket belongs to the local day that contains its midpoint, and is priced with the same UTC day's mix from that account's Codex folder.
Days without a usable local mix use the period's average rate, and the app hides dollars when no day has one.

## Weekly capacity

```text
current implied capacity = current-window observed tokens × 100 / official weekly percent
Codex weekly value = current-window estimated cost × 100 / official weekly percent
```

Codex extrapolates only current-window observations at or above 3% weekly usage.
A falling weekly percentage within one reset window invalidates that window's projection.
It does not multiply a previous window's token capacity by the current model mix; quota consumption can change when the model mix changes.
If the account counter has not increased or still trails a complete local weekly ledger, Codex uses that local ledger.
The estimate stays unavailable without a current-window sample or priced model mix, instead of preserving a stale dollar amount.
With several accounts, a provider header sums each account's available estimate, counting the same login once.
Extra accounts project only their own current-window records, without the primary Claude account's smoothing.

Claude uses available local records inside the official 7-day interval.
Its current-window observations become eligible at 3% used.
Earlier windows with at least 10% usage can supply same-source priors.
Claude priors and the current observation are API-equivalent dollars; equivalent tokens are derived from the current mix for display.
Token Bar retains 12 Claude samples for 70 days, removes large median-absolute-deviation outliers, and blends the robust prior with the current observation in log space.
Observations from the same quota bucket and source with start and reset times less than two seconds apart count as one window, retaining its latest sample, including when loading older history.
Another computer can raise the Claude percentage without adding records on this Mac.

Codex uses:

```text
current lifetimeTokens - recorded near-start lifetimeTokens
```

The difference can include another computer on the same account.
Until Token Bar accepts an account baseline, it uses the available local Codex 7-day ledger as a fallback.
The account-wide projection uses this Mac's current-window model mix to price account tokens.
The local fallback requires an exact token match between the ledger and its price mix.

## ImageGen output estimates

Token Bar estimates saved PNG outputs under `~/.codex/generated_images`.
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
  sum(account estimated weekly tokens × account weekly percent)
  / sum(account estimated weekly tokens)
```

The Claude and Codex headers apply the same weighting to their own accounts.
An account without an estimate takes its provider's mean weight, and a provider without any estimate weights its accounts equally.

All is an app-defined weighted estimate, not a provider-issued shared quota.
All remains unavailable until both providers have usable capacity evidence.

## Limits

- Daily rates are frozen from the first observation and kept for 400 days; earlier history uses the rates available when it was first priced.
- Speed and long-context adjustments require recorded request metadata and a published rate.
- Account counters, local records and quota percentages may differ in scope and update timing; the near-start baseline can omit initial usage.
- Applying a local price mix to account totals assumes representative models and token categories, with matching calendar dates.
- Completed local scans include Codex archives but not other hosts, so they do not establish whole-account coverage.
- A falling projection alone does not prove a quota reduction or poor image value.
- Claude cleanup can remove old local sessions.
- Remote Codex usage lacks a remote model and category breakdown.
- Internal model labels without a documented price remain unpriced.

Claude records deduplicate by `message.id + requestId`, using whichever identifier exists when only one does.
Codex records prefer `last_token_usage`, fall back to cumulative deltas, reject repeated totals, and suppress copied history at the start of forked sessions.

Official prices determine rates, not account coverage or prediction accuracy.
