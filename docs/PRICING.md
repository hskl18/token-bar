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
  + separately billed reasoning × output rate
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

The current estimate starts at 3% used.
Observations at 10% or more can become prior samples.
Token Bar retains 12 samples for 70 days, removes large median-absolute-deviation outliers, and blends the robust prior with the current observation in log space.

Claude uses complete local records inside the official 7-day interval.
Another computer can raise the Claude percentage without adding records on this Mac.

Codex uses:

```text
current lifetimeTokens - lifetimeTokens captured at window start
```

The difference can include another computer on the same account.
Until Token Bar captures a start-aligned baseline, it uses the complete local Codex 7-day ledger as a temporary fallback.
Account-wide and local-only samples keep separate histories.

## Combined percentage

Claude and Codex can have different weekly capacities, so Token Bar uses a weighted result:

```text
All percent =
  sum(provider capacity × provider weekly percent)
  / sum(provider capacity)
```

The app does not average the two percentages.
All remains unavailable until both providers have usable capacity evidence.

## Limits

- Current standard prices apply to retained history rather than reconstructing old price changes.
- Logs can omit service tier, long-context threshold, region, fast mode, batch mode, or tool charges.
- Claude cleanup can remove old local sessions.
- Remote Codex usage lacks a remote model and category breakdown.
- Internal model labels without a documented price remain unpriced.

Claude records deduplicate by `message.id + requestId` when both fields exist.
Codex records prefer `last_token_usage`, fall back to cumulative deltas, reject repeated totals, and suppress copied history at the start of forked sessions.

Official provider tables remain authoritative when sources disagree.
