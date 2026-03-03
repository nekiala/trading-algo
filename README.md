# trading-algo

Forex and XAUUSD trading algo — MQL5 Expert Advisor for MetaTrader 5.

## Overview

`TradingRobot.mq5` is a fully automated Expert Advisor (EA) written in MQL5 for MetaTrader 5. It implements a disciplined, rule-based trading strategy for **EURUSD** and **XAUUSD** on the **H1** timeframe, using **H4** for trend confirmation.

---

## Features

### 1. Capital Management
| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskPercent` | 1.0% | Maximum risk per trade as % of balance |
| `InpRiskRewardMin` | 2.0 | Minimum Risk/Reward ratio (1:2) |
| `InpMaxTradesPerDay` | 3 | Maximum number of trades per day |
| `InpMaxDailyLossPct` | 3.0% | Daily loss limit — stops all trading for the day |

- Stop Loss is **mandatory** on every trade (calculated via ATR).
- Lot size is automatically calculated to risk exactly `InpRiskPercent` of balance.

### 2. Supported Assets
- **EURUSD**
- **XAUUSD**

Attach the EA to an **H1 chart** of either symbol.

### 3. Timeframes Used
| Timeframe | Role |
|-----------|------|
| H4 | Trend confirmation (Higher High / Higher Low detection) |
| H1 | Entry signals, RSI, volume, pullback (EA runs on this TF) |

### 4. Entry Conditions — BUY
1. H4 uptrend confirmed (Higher High + Higher Low pattern)
2. RSI(14) on H4 between 40–60 with a bullish bounce on H1
3. Resistance breakout on H1 with volume > `InpVolumeMultiplier × average`
4. Pullback confirmed (price retraced then resumed up)

### 5. Entry Conditions — SELL
1. H4 downtrend confirmed (Lower High + Lower Low pattern)
2. RSI(14) on H4 between 40–60 with a bearish rejection on H1
3. Support breakdown on H1 with high volume
4. Pullback confirmed (bounce then resumed down)

### 6. Mandatory Filters
- **News filter**: No trading within ±`InpNewsFilterMinutes` (default 30 min) of major scheduled news events (NFP, Fed, ECB, CPI, etc.)
- **Range filter**: Skips trading when H1 ATR is too small relative to H4 ATR (tight range)
- **Volatility filter**: Skips trading when current ATR falls below `InpMinATRMultiplier × average ATR`

### 7. Continuous Optimization
- Analyzes the last `InpOptimizeTrades` (default 20) closed trades
- If drawdown exceeds `InpMaxDrawdownPct` (default 5%), risk is automatically halved
- If win rate falls below `InpMinWinRate` (default 55%), risk is reduced
- Risk is restored once conditions normalize

### 8. Trade Journal
All trades are logged to `TradeJournal.csv` inside MetaTrader's `MQL5/Files/` directory.

Logged fields:
- DateTime, Ticket, Symbol, Type, Lots, Entry Price, SL, TP, Reason, Status (WIN/LOSS)

---

## Installation

1. Copy `TradingRobot.mq5` to your MetaTrader 5 `MQL5/Experts/` folder.
2. Open MetaEditor and compile the file (`F7`).
3. Attach the compiled EA to an **H1 chart** of **EURUSD** or **XAUUSD**.
4. Enable **Algo Trading** in MetaTrader 5.
5. Adjust input parameters as needed.

> **Note on News Filter**: The built-in news schedule uses a static list of common high-impact events. For live trading, integrate a real-time economic calendar feed for precise news filtering.

---

## Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskPercent` | 1.0 | Risk per trade (% of balance) |
| `InpRiskRewardMin` | 2.0 | Minimum R/R ratio |
| `InpMaxTradesPerDay` | 3 | Max trades per day |
| `InpMaxDailyLossPct` | 3.0 | Daily loss limit (%) |
| `InpRSIPeriod` | 14 | RSI period |
| `InpRSILower` | 40.0 | RSI lower bound |
| `InpRSIUpper` | 60.0 | RSI upper bound |
| `InpNewsFilterMinutes` | 30 | Minutes around news to avoid |
| `InpVolumePeriod` | 20 | Volume MA period |
| `InpVolumeMultiplier` | 1.2 | Volume multiplier for breakout confirmation |
| `InpATRPeriod` | 14 | ATR period |
| `InpMinATRMultiplier` | 0.5 | Min ATR ratio for volatility filter |
| `InpRangeATRMultiplier` | 0.3 | ATR ratio threshold for range filter |
| `InpSwingLookback` | 10 | Bars for swing H/L detection on H4 |
| `InpPullbackBars` | 5 | Bars to confirm pullback |
| `InpATRSLMultiplier` | 1.5 | ATR multiplier for Stop Loss distance |
| `InpRSITolerance` | 2.0 | RSI tolerance for bounce/rejection detection |
| `InpJournalFile` | `TradeJournal.csv` | Trade journal filename |
| `InpOptimizeTrades` | 20 | Trades to analyze for optimization |
| `InpMaxDrawdownPct` | 5.0 | Drawdown threshold for risk reduction (%) |
| `InpMinWinRate` | 55.0 | Minimum win rate (%) |
| `InpRiskReductionFactor` | 0.5 | Risk multiplier when optimization triggers |

---

## Disclaimer

This EA is provided for educational purposes. Past performance does not guarantee future results. Always test in a demo account before live trading.
