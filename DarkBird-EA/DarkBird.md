# DarkBird MT5 — Technical and Academic Documentation

**Version:** 1.00
**Platform:** MetaTrader 5 (MQL5)
**Category:** Multi-entry scalping Expert Advisor
**Recommended Instrument:** XAUUSD (Gold/USD)
**Recommended Timeframe:** M1

---

## Abstract

DarkBird is a short-term scalping Expert Advisor (EA) that combines trend following, momentum
confirmation, and a mean-reversion trigger within a single decision framework. The system derives
directional bias from an EMA(9)/EMA(21) crossover, confirms momentum with RSI(14), and generates
entry signals from a pullback-and-reclaim pattern around the Bollinger Bands midline (SMA-20, 2σ).
Position sizing is computed via an `OrderCalcProfit`-based method that risks a fixed percentage of
account equity per trade. The system is supported by adaptive trade-management components,
including ATR-adaptive stop-loss/take-profit distances, a stepped trailing stop, a breakeven lock,
a time-based stop, and early exit on adverse signal reversal. A daily loss guard and an aggregate
open-risk cap form the account-level capital-preservation layer.

This document describes the algorithmic architecture of the EA within an academic framework,
details the risk-management design, and provides an observational assessment of the supplied
backtest equity curve.

---

## 1. Introduction

Short-term (scalping) strategies operate on low timeframes (such as M1) with high trade frequency
and comparatively small profit targets, which increases their dependence on both execution speed
and strict risk control. DarkBird is designed to meet these requirements through a per-tick
position-management loop and a multi-layered entry-filtering mechanism.

---

## 2. Strategy Methodology

The system relies on the confluence of three independent indicators:

| Component | Indicator | Role |
|---|---|---|
| Trend | EMA(9) / EMA(21) | Determines market direction (Fast EMA > Slow EMA → bullish bias) |
| Momentum | RSI(14) | Confirms momentum alignment with the trend; entries are blocked in overbought/oversold zones |
| Trigger | Bollinger Bands (20, 2σ) | Looks for a pullback to the midline followed by price reclaiming it |

**BUY condition:** Bullish trend + RSI above 50 and rising + the last closed bar's low touched the
midline + live price has reclaimed the midline + no breakdown below the lower band.

**SELL condition:** The mirror image of the above (bearish trend, RSI below 50 and falling,
pullback to the upper band followed by price returning below the midline).

This structure ensures that positions are opened only when momentum is aligned with the prevailing
trend and price is returning from a temporary pullback, implementing an "in-trend pullback" logic.

---

## 3. Risk Management Architecture

| Layer | Mechanism |
|---|---|
| Position size | A fixed percentage of equity (`InpRiskPercent`) is converted to lot size based on the actual monetary loss computed via `OrderCalcProfit`; the trade is skipped if margin is insufficient |
| Stop distance | ATR(14)-based adaptive SL/TP (`InpSL_AtrMult`, `InpTP_AtrMult`) or a fixed-point alternative; the broker's minimum stop distance is always respected |
| Daily loss guard | New entries are halted once equity falls by `InpMaxDailyLossPct` relative to the daily starting equity (existing positions continue to be managed) |
| Aggregate open-risk cap | The sum of worst-case losses across open positions is capped at `InpMaxOpenRiskPct` of equity |
| Spread filter | Entries are blocked when the spread exceeds `InpMaxSpreadPoints` |
| Anti-clustering | A new same-direction entry cannot be opened within `InpMinEntryStepPoints` of the previous one, nor before the `InpEntryCooldownSec` cooldown has elapsed |
| Position limits | Maximum number of positions per direction (`InpMaxPosPerDirection`) and in total (`InpMaxTotalPositions`) |

This layered structure is intended to limit the impact of any single erroneous signal on the
account and to prevent new entries when market liquidity has deteriorated (e.g., spread widening).

---

## 4. Adaptive Trade Management

Open positions are evaluated on every tick in the following order:

1. **Time-stop:** If a position has been open longer than `InpMaxTradeSec` and remains in loss, it
   is closed.
2. **Early exit (adverse signal):** If the trend reverses, RSI crosses the momentum threshold in
   the adverse direction, or price breaks the opposing band, the position is closed before the
   stop-loss is reached.
3. **Breakeven lock:** Once profit reaches `InpBETriggerPoints`, the stop-loss is moved to lock in
   `InpBEOffsetPoints` of profit.
4. **Stepped trailing stop:** Once profit exceeds the sum of the trailing distance and the step
   threshold, the stop-loss is advanced in meaningful increments of `InpTrailStepPoints`.

This ordering prioritizes capital preservation (time-based/signal-based exits) ahead of profit
locking (breakeven/trailing).

---

## 5. Parameter Reference

| Group | Parameter | Default | Description |
|---|---|---|---|
| Risk | InpRiskPercent | 1.0 | Percentage of equity risked per trade |
| Risk | InpMaxDailyLossPct | 3.0 | Daily loss limit |
| Risk | InpMaxOpenRiskPct | 4.0 | Aggregate open-risk cap |
| Risk | InpMaxSpreadPoints | 25 | Maximum allowed spread |
| Risk | InpMaxPosPerDirection / InpMaxTotalPositions | 3 / 6 | Position-count limits |
| SL/TP | InpUseATRStops | true | Whether to use ATR-based or fixed stops |
| SL/TP | InpSL_AtrMult / InpTP_AtrMult | 1.5 / 2.5 | ATR multipliers |
| Management | InpBETriggerPoints / InpBEOffsetPoints | 120 / 20 | Breakeven trigger and offset |
| Management | InpTrailPoints / InpTrailStepPoints | 150 / 30 | Trailing-stop distance and step |
| Indicators | InpFastEMA / InpSlowEMA | 9 / 21 | Trend EMA periods |
| Indicators | InpRSIPeriod, InpRSI_OB/OS | 14, 70/30 | RSI period and overbought/oversold thresholds |
| Indicators | InpBBPeriod, InpBBDev | 20, 2.0 | Bollinger period and deviation |
| Identification | InpMagic | 20260731 | Unique identifier for the EA's own positions |

---

## 6. Optimal Trading Environment: XAUUSD / M1

Based on usage experience, the EA has been found to deliver its most consistent results on
**XAUUSD at the M1 timeframe**. The structural rationale can be summarized as follows:

- **ATR-adaptive stops:** Because gold's intraday volatility is highly variable, ATR(14)-based
  SL/TP distances scale automatically with the prevailing market regime, providing a stop placement
  better suited to the elevated noise levels of the M1 timeframe than a fixed-point alternative.
- **High trade frequency:** The M1 timeframe allows the EMA/RSI/Bollinger confluence to trigger
  frequently, which is consistent with a scalping approach.
- **Account-type note:** As indicated in the source code, the account must operate in *hedging*
  mode for multiple same-direction positions to be retained as separate tickets; on *netting*
  accounts, same-direction entries merge into a single net position.

This observation reflects a general tendency rather than a guarantee, since results may vary under
different market conditions (news flow, liquidity sessions, broker execution quality).

---

## 7. Backtest Findings — Equity Curve Analysis

### 7.1 Test Parameters

| Parameter | Value |
|---|---|
| Instrument | XAUUSD |
| Timeframe | M1 |
| Test duration | 1 month |
| Initial capital | $5,000.00 |
| Leverage | 1:15 |
| Ending equity | $11,212.00 |
| Net profit | $6,212.00 |
| Return on initial capital | +124.24% |

### 7.2 Equity Curve Observations

The following observations are based on a visual review of the Strategy Tester equity/balance
chart provided:

- **Overall trend:** Across the one-month test window, the equity curve exhibits a stepped
  ("staircase") upward pattern without a sustained decline — extended consolidation (sideways)
  phases are followed by pronounced breakout advances, consistent with the compounding growth from
  $5,000 to $11,212 over the period.
- **Balance–equity convergence:** The green (equity) and blue (balance) lines overlap almost
  entirely throughout the test, indicating that the floating profit/loss amplitude of open
  positions remained limited and that positions were closed relatively quickly — consistent with
  the EA's early-exit and trailing/breakeven mechanisms.
- **Drawdowns:** Periodic minor pullbacks are visible, most notably a short consolidation band in
  the mid-section of the curve, but none interrupt the overall upward trajectory; a brief
  retracement from the local peak is present near the end of the test.
- **Acceleration phases:** Two distinct acceleration segments are visible — one roughly a third of
  the way through the test and one toward the final quarter — where the slope of the curve steepens
  noticeably before returning to a shallower, range-bound pace.

### 7.3 Interpretation

A one-month return of +124.24% on $5,000 of initial capital under 1:15 leverage represents a
substantial result by any conventional benchmark. Academically, this figure should be interpreted
with caution for the following reasons:

- **Sample size:** A single one-month test constitutes one realization of a stochastic process;
  it does not, by itself, establish the strategy's expected return or its variance across
  different market regimes.
- **Leverage amplification:** At 1:15, both gains and losses are amplified proportionally; the
  same equity curve shape at a lower leverage ratio would correspond to a materially smaller
  absolute return, and vice versa for higher leverage.
- **Missing risk metrics:** The supplied chart does not report maximum drawdown, win rate, profit
  factor, or trade count. A high absolute return figure is not, on its own, informative about
  risk-adjusted performance (e.g., return per unit of drawdown); these metrics are necessary before
  the result can be considered statistically meaningful.

Once the full Strategy Tester report (HTML/PDF output, or the summary table from the "Results"
tab) is made available, this section can be extended with drawdown, win-rate, and risk-adjusted
performance statistics.

---

## 8. Limitations and Recommendations

- **Account-type dependency:** The pyramiding logic (multiple same-direction positions) functions
  as designed only on hedging accounts.
- **Execution sensitivity:** M1 scalping requires low latency and a stable VPS/broker
  infrastructure; live-market slippage and requotes may cause results to deviate from those
  observed in backtesting.
- **Overfitting risk:** Parameters optimized on short timeframes may underperform in different
  market regimes (low volatility, news-driven shocks); walk-forward or out-of-sample validation is
  recommended.
- **Single-symbol assumption:** Because position counting and risk calculations are scoped to
  `_Symbol`, aggregate risk must be tracked manually when the EA is run on multiple symbols within
  the same account.

---

## 9. Conclusion

DarkBird is an MT5 scalping EA that combines trend, momentum, and mean-reversion components
within a multi-layered risk-control framework. The architecture is designed to prioritize capital
preservation (daily/aggregate risk limits, spread filtering) over profit optimization (ATR-adaptive
targets, stepped trailing). The XAUUSD/M1 combination is recommended on the grounds that
ATR-based adaptive stop logic aligns well with gold's variable volatility structure. The supplied
equity curve points to a stable performance pattern with a limited floating-risk profile; however,
a definitive performance assessment requires review of the complete numerical backtest report.

---

## Disclaimer

This document is provided for technical and academic informational purposes only and does not
constitute investment advice. Past backtest performance is not a guarantee of future results; live
market conditions (spread, slippage, liquidity) may differ from those observed in the backtest
environment.
