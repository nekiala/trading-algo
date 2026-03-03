//+------------------------------------------------------------------+
//|                                               TradingRobot.mq5  |
//|                         Forex & XAUUSD Expert Advisor (MQL5)    |
//+------------------------------------------------------------------+
#property copyright "Trading Algo"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+

// --- Capital Management ---
input group "=== Capital Management ==="
input double InpRiskPercent       = 1.0;    // Risk per trade (% of balance)
input double InpRiskRewardMin     = 2.0;    // Minimum Risk/Reward ratio
input int    InpMaxTradesPerDay   = 3;      // Maximum trades per day
input double InpMaxDailyLossPct   = 3.0;   // Daily loss limit (%)

// --- RSI Settings ---
input group "=== RSI Parameters ==="
input int    InpRSIPeriod         = 14;     // RSI period
input double InpRSILower          = 40.0;  // RSI lower bound
input double InpRSIUpper          = 60.0;  // RSI upper bound

// --- News Filter ---
input group "=== News Filter ==="
input int    InpNewsFilterMinutes = 30;     // Minutes before/after major news to avoid trading

// --- Volume & ATR ---
input group "=== Volatility & Volume ==="
input int    InpVolumePeriod      = 20;     // Volume MA period
input double InpVolumeMultiplier  = 1.2;   // Volume multiplier above average for breakout
input int    InpATRPeriod         = 14;     // ATR period
input double InpMinATRMultiplier  = 0.5;   // Minimum ATR multiplier for volatility check
input double InpRangeATRMultiplier= 0.3;   // ATR multiplier threshold for range detection

// --- Trend Detection ---
input group "=== Trend Detection ==="
input int    InpSwingLookback     = 10;     // Bars to look back for swing high/low detection
input int    InpPullbackBars      = 5;      // Bars to confirm pullback

// --- SL/TP ---
input group "=== Stop Loss / Take Profit ==="
input double InpATRSLMultiplier   = 1.5;   // ATR multiplier for Stop Loss distance
input double InpRSITolerance      = 2.0;   // RSI tolerance for bounce/rejection detection

// --- Optimization ---
input group "=== Optimization Risk Adjustment ==="
input double InpRiskReductionFactor = 0.5; // Factor to reduce risk when drawdown/win rate is poor

// --- Trade Journal ---
input group "=== Journal ==="
input string InpJournalFile       = "TradeJournal.csv";  // Trade journal filename

// --- Performance Optimization ---
input group "=== Optimization ==="
input int    InpOptimizeTrades    = 20;     // Number of last trades to analyze
input double InpMaxDrawdownPct    = 5.0;   // Drawdown threshold for parameter adjustment (%)
input double InpMinWinRate        = 55.0;  // Minimum win rate (%)

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade         Trade;
CPositionInfo  PositionInfo;

// Daily tracking
datetime g_lastDailyReset  = 0;
int      g_tradesToday     = 0;
double   g_dailyStartBalance = 0.0;

// Indicator handles
int g_hRSI_H4   = INVALID_HANDLE;
int g_hRSI_H1   = INVALID_HANDLE;
int g_hATR_H1   = INVALID_HANDLE;
int g_hATR_H4   = INVALID_HANDLE;

// Performance tracking
int    g_totalTrades     = 0;
int    g_winningTrades   = 0;
double g_peakBalance     = 0.0;
bool   g_optimizeMode    = false;

// Adjusted risk in optimize mode
double g_currentRiskPct  = 0.0;

// Magic number constant (must match Trade.SetExpertMagicNumber value)
const long EA_MAGIC              = 202600001;
const int  HISTORY_LOOKBACK_SECS = 86400 * 30; // 30-day history window for trade analysis

//+------------------------------------------------------------------+
//| Expert Advisor Initialization                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    // Validate symbol
    string sym = Symbol();
    if(sym != "EURUSD" && sym != "XAUUSD")
    {
        Alert("TradingRobot: Only EURUSD and XAUUSD are supported. Current symbol: ", sym);
        return INIT_FAILED;
    }

    // Validate timeframe - EA should run on H1
    if(Period() != PERIOD_H1)
    {
        Alert("TradingRobot: Please attach EA to H1 chart. Current period: ", EnumToString(Period()));
        return INIT_FAILED;
    }

    // Create indicator handles
    g_hRSI_H4 = iRSI(sym, PERIOD_H4, InpRSIPeriod, PRICE_CLOSE);
    g_hRSI_H1 = iRSI(sym, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
    g_hATR_H1 = iATR(sym, PERIOD_H1, InpATRPeriod);
    g_hATR_H4 = iATR(sym, PERIOD_H4, InpATRPeriod);

    if(g_hRSI_H4 == INVALID_HANDLE || g_hRSI_H1 == INVALID_HANDLE ||
       g_hATR_H1 == INVALID_HANDLE || g_hATR_H4 == INVALID_HANDLE)
    {
        Alert("TradingRobot: Failed to create indicator handles.");
        return INIT_FAILED;
    }

    // Initialize state
    g_currentRiskPct   = InpRiskPercent;
    g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_peakBalance       = g_dailyStartBalance;
    g_lastDailyReset    = 0;

    // Set trade magic number
    Trade.SetExpertMagicNumber(EA_MAGIC);
    Trade.SetDeviationInPoints(20);

    // Initialize journal file with header if not exists
    InitJournal();

    Print("TradingRobot initialized on ", sym, " H1.");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert Advisor Deinitialization                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_hRSI_H4 != INVALID_HANDLE) IndicatorRelease(g_hRSI_H4);
    if(g_hRSI_H1 != INVALID_HANDLE) IndicatorRelease(g_hRSI_H1);
    if(g_hATR_H1 != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
    if(g_hATR_H4 != INVALID_HANDLE) IndicatorRelease(g_hATR_H4);
    Print("TradingRobot deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main Tick Handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
    // Only process on new H1 bar
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(Symbol(), PERIOD_H1, 0);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    // Reset daily stats if new day
    ResetDailyStats();

    // Update performance tracking
    UpdatePerformance();

    // Check optimization thresholds and adjust risk
    CheckOptimization();

    // Check daily loss limit
    if(IsDailyLossLimitReached())
    {
        Print("Daily loss limit reached. No new trades today.");
        return;
    }

    // Check daily trade count
    if(g_tradesToday >= InpMaxTradesPerDay)
    {
        Print("Maximum trades per day reached (", InpMaxTradesPerDay, ").");
        return;
    }

    // Mandatory filters
    if(!CheckVolatilityFilter())   { Print("Low volatility detected. Skipping."); return; }
    if(!CheckRangeFilter())        { Print("Tight range market detected. Skipping."); return; }
    if(!CheckNewsFilter())         { Print("Near major news. Skipping."); return; }

    // Determine trend on H4
    int h4Trend = GetH4Trend();  // 1 = bullish, -1 = bearish, 0 = undefined

    if(h4Trend == 0) { Print("H4 trend undefined. Skipping."); return; }

    // Check RSI conditions
    double rsiH4[1];
    if(CopyBuffer(g_hRSI_H4, 0, 1, 1, rsiH4) <= 0) return;

    double rsi4 = rsiH4[0];

    bool rsiInRange = (rsi4 >= InpRSILower && rsi4 <= InpRSIUpper);

    // Check for BUY setup
    if(h4Trend == 1 && rsiInRange && IsRSIBullishBounce() &&
       IsResistanceBreakoutWithVolume() && IsPullbackConfirmed(true))
    {
        double sl = 0.0, tp = 0.0;
        if(CalculateSLTP(true, sl, tp))
        {
            double lots = CalculateLotSize(sl);
            if(lots > 0.0)
            {
                string reason = StringFormat("BUY: H4 uptrend, RSI=%.1f, resistance breakout, pullback", rsi4);
                OpenTrade(ORDER_TYPE_BUY, lots, sl, tp, reason);
            }
        }
    }

    // Check for SELL setup
    if(h4Trend == -1 && rsiInRange && IsRSIBearishRejection() &&
       IsSupportBreakoutWithVolume() && IsPullbackConfirmed(false))
    {
        double sl = 0.0, tp = 0.0;
        if(CalculateSLTP(false, sl, tp))
        {
            double lots = CalculateLotSize(sl);
            if(lots > 0.0)
            {
                string reason = StringFormat("SELL: H4 downtrend, RSI=%.1f, support break, pullback", rsi4);
                OpenTrade(ORDER_TYPE_SELL, lots, sl, tp, reason);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Reset daily tracking at start of new day                        |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);
    MqlDateTime last;
    TimeToStruct(g_lastDailyReset, last);

    if(now.day != last.day || now.mon != last.mon || now.year != last.year)
    {
        g_tradesToday       = 0;
        g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        g_lastDailyReset    = TimeCurrent();
        Print("Daily stats reset. Balance: ", g_dailyStartBalance);
    }
}

//+------------------------------------------------------------------+
//| Check if daily loss limit is reached                            |
//+------------------------------------------------------------------+
bool IsDailyLossLimitReached()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double lossAmt = g_dailyStartBalance - balance;
    double lossPct = (g_dailyStartBalance > 0.0) ? (lossAmt / g_dailyStartBalance) * 100.0 : 0.0;
    return (lossPct >= InpMaxDailyLossPct);
}

//+------------------------------------------------------------------+
//| News filter: avoid ±InpNewsFilterMinutes around major news      |
//| Uses a hardcoded weekly schedule of common high-impact sessions. |
//| For live usage, integrate a news calendar API or CSV feed.      |
//+------------------------------------------------------------------+
bool CheckNewsFilter()
{
    // Known high-impact UTC times (day-of-week, hour, minute)
    // Format: {dayOfWeek (1=Mon..5=Fri), hour, minute}
    // This is a representative set; update periodically.
    int newsSchedule[][3] =
    {
        {2, 13, 30},  // Tuesday US retail sales / CPI approx
        {3, 13, 30},  // Wednesday Fed minutes / ADP approx
        {4, 12, 45},  // Thursday ECB decision approx
        {4, 13, 30},  // Thursday US jobless claims
        {5, 13, 30}   // Friday NFP
    };

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int currentDow   = dt.day_of_week; // 0=Sun,1=Mon,...,6=Sat
    int currentHour  = dt.hour;
    int currentMin   = dt.min;
    int currentMins  = currentHour * 60 + currentMin;

    for(int i = 0; i < ArrayRange(newsSchedule, 0); i++)
    {
        int newsDow  = newsSchedule[i][0];
        int newsHour = newsSchedule[i][1];
        int newsMins = newsSchedule[i][2];
        int newsTime = newsHour * 60 + newsMins;

        if(currentDow == newsDow)
        {
            int diff = MathAbs(currentMins - newsTime);
            if(diff <= InpNewsFilterMinutes)
                return false; // Too close to news
        }
    }
    return true;
}

//+------------------------------------------------------------------+
//| Volatility filter: skip if ATR is too low                       |
//+------------------------------------------------------------------+
bool CheckVolatilityFilter()
{
    double atrH1[2];
    if(CopyBuffer(g_hATR_H1, 0, 1, 2, atrH1) <= 0) return false;

    double currentATR = atrH1[0];
    double avgATR     = (atrH1[0] + atrH1[1]) / 2.0;

    if(avgATR <= 0.0) return false;
    return (currentATR >= InpMinATRMultiplier * avgATR);
}

//+------------------------------------------------------------------+
//| Range filter: skip if market is in a tight range                |
//+------------------------------------------------------------------+
bool CheckRangeFilter()
{
    double atrH1[1], atrH4[1];
    if(CopyBuffer(g_hATR_H1, 0, 1, 1, atrH1) <= 0) return false;
    if(CopyBuffer(g_hATR_H4, 0, 1, 1, atrH4) <= 0) return false;

    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    if(point <= 0.0) return false;

    // If H1 ATR is less than InpRangeATRMultiplier * H4 ATR, consider it a range
    return (atrH1[0] >= InpRangeATRMultiplier * atrH4[0]);
}

//+------------------------------------------------------------------+
//| Determine H4 trend: Higher High / Higher Low = bullish,        |
//|                     Lower High / Lower Low   = bearish          |
//+------------------------------------------------------------------+
int GetH4Trend()
{
    int lb = InpSwingLookback;
    double highs[], lows[];
    ArrayResize(highs, lb);
    ArrayResize(lows, lb);

    for(int i = 0; i < lb; i++)
    {
        highs[i] = iHigh(Symbol(), PERIOD_H4, i + 1);
        lows[i]  = iLow(Symbol(), PERIOD_H4, i + 1);
    }

    // Find two swing highs and two swing lows
    double sh1 = -1, sh2 = -1, sl1 = -1, sl2 = -1;
    int    sh1i = -1, sl1i = -1;

    for(int i = 1; i < lb - 1; i++)
    {
        // Swing high
        if(highs[i] > highs[i-1] && highs[i] > highs[i+1])
        {
            if(sh1 < 0) { sh1 = highs[i]; sh1i = i; }
            else if(sh2 < 0) { sh2 = highs[i]; break; }
        }
    }

    for(int i = 1; i < lb - 1; i++)
    {
        // Swing low
        if(lows[i] < lows[i-1] && lows[i] < lows[i+1])
        {
            if(sl1 < 0) { sl1 = lows[i]; sl1i = i; }
            else if(sl2 < 0) { sl2 = lows[i]; break; }
        }
    }

    bool hhhl = (sh1 > 0 && sh2 > 0 && sh1 > sh2) &&
                (sl1 > 0 && sl2 > 0 && sl1 > sl2);
    bool lhll = (sh1 > 0 && sh2 > 0 && sh1 < sh2) &&
                (sl1 > 0 && sl2 > 0 && sl1 < sl2);

    if(hhhl) return  1; // Bullish
    if(lhll) return -1; // Bearish
    return 0;            // Undefined
}

//+------------------------------------------------------------------+
//| Check RSI bullish bounce on H1                                  |
//+------------------------------------------------------------------+
bool IsRSIBullishBounce()
{
    double rsi[3];
    if(CopyBuffer(g_hRSI_H1, 0, 1, 3, rsi) <= 0) return false;
    // Bounce: RSI dipped then rose back into lower range
    return (rsi[2] < InpRSILower && rsi[1] < rsi[2] + InpRSITolerance && rsi[0] > rsi[1]);
}

//+------------------------------------------------------------------+
//| Check RSI bearish rejection on H1                               |
//+------------------------------------------------------------------+
bool IsRSIBearishRejection()
{
    double rsi[3];
    if(CopyBuffer(g_hRSI_H1, 0, 1, 3, rsi) <= 0) return false;
    // Rejection: RSI spiked then fell back into upper range
    return (rsi[2] > InpRSIUpper && rsi[1] > rsi[2] - InpRSITolerance && rsi[0] < rsi[1]);
}

//+------------------------------------------------------------------+
//| Resistance breakout with volume > average on H1                 |
//+------------------------------------------------------------------+
bool IsResistanceBreakoutWithVolume()
{
    int lookback = InpVolumePeriod + 1;
    double highs[];
    long   volumes[];
    ArrayResize(highs,   lookback);
    ArrayResize(volumes, lookback);

    for(int i = 0; i < lookback; i++)
    {
        highs[i]   = iHigh(Symbol(), PERIOD_H1, i + 1);
        volumes[i] = iVolume(Symbol(), PERIOD_H1, i + 1);
    }

    // Resistance = highest high over lookback period (excluding most recent confirmed bar)
    double resistance = highs[1];
    for(int i = 2; i < lookback; i++)
        if(highs[i] > resistance) resistance = highs[i];

    double currentClose = iClose(Symbol(), PERIOD_H1, 1);

    // Volume average
    double volSum = 0;
    for(int i = 1; i < lookback; i++) volSum += (double)volumes[i];
    double volAvg = volSum / (double)(lookback - 1);

    bool broke     = (currentClose > resistance);
    bool highVol   = ((double)volumes[1] >= InpVolumeMultiplier * volAvg);

    return (broke && highVol);
}

//+------------------------------------------------------------------+
//| Support breakout (break below) with volume > average on H1      |
//+------------------------------------------------------------------+
bool IsSupportBreakoutWithVolume()
{
    int lookback = InpVolumePeriod + 1;
    double lows[];
    long   volumes[];
    ArrayResize(lows,    lookback);
    ArrayResize(volumes, lookback);

    for(int i = 0; i < lookback; i++)
    {
        lows[i]    = iLow(Symbol(), PERIOD_H1, i + 1);
        volumes[i] = iVolume(Symbol(), PERIOD_H1, i + 1);
    }

    // Support = lowest low over lookback period
    double support = lows[1];
    for(int i = 2; i < lookback; i++)
        if(lows[i] < support) support = lows[i];

    double currentClose = iClose(Symbol(), PERIOD_H1, 1);

    double volSum = 0;
    for(int i = 1; i < lookback; i++) volSum += (double)volumes[i];
    double volAvg = volSum / (double)(lookback - 1);

    bool broke   = (currentClose < support);
    bool highVol = ((double)volumes[1] >= InpVolumeMultiplier * volAvg);

    return (broke && highVol);
}

//+------------------------------------------------------------------+
//| Pullback confirmation                                           |
//| isBuy=true: price retraced after breakout (still above support) |
//| isBuy=false: price bounced after breakdown (still below resist) |
//+------------------------------------------------------------------+
bool IsPullbackConfirmed(bool isBuy)
{
    int lb = InpPullbackBars;
    double closes[];
    ArrayResize(closes, lb + 1);
    for(int i = 0; i <= lb; i++)
        closes[i] = iClose(Symbol(), PERIOD_H1, i + 1);

    if(isBuy)
    {
        // After breakout, price should have pulled back at least one bar then resumed up
        // Simplistic check: most recent bar closed higher than one bar before
        return (closes[0] > closes[1] && closes[1] < closes[2]);
    }
    else
    {
        // After breakdown, price bounced up, then resumed down
        return (closes[0] < closes[1] && closes[1] > closes[2]);
    }
}

//+------------------------------------------------------------------+
//| Calculate Stop Loss and Take Profit                             |
//+------------------------------------------------------------------+
bool CalculateSLTP(bool isBuy, double &sl, double &tp)
{
    double atr[1];
    if(CopyBuffer(g_hATR_H1, 0, 1, 1, atr) <= 0) return false;

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double spread = ask - bid;

    double slDistance = atr[0] * InpATRSLMultiplier + spread;
    double tpDistance = slDistance * InpRiskRewardMin;

    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

    if(isBuy)
    {
        sl = NormalizeDouble(ask - slDistance, digits);
        tp = NormalizeDouble(ask + tpDistance, digits);
    }
    else
    {
        sl = NormalizeDouble(bid + slDistance, digits);
        tp = NormalizeDouble(bid - tpDistance, digits);
    }

    // Validate minimum distance
    double minStop = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) *
                     SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    if(isBuy)
    {
        if(ask - sl < minStop || tp - ask < minStop) return false;
    }
    else
    {
        if(sl - bid < minStop || bid - tp < minStop) return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on fixed risk percentage               |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl)
{
    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (g_currentRiskPct / 100.0);

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double price = (sl < ask) ? ask : bid;   // approximate entry

    double slDistance  = MathAbs(price - sl);
    if(slDistance <= 0.0) return 0.0;

    double tickValue   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double tickSize    = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
    if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

    double valuePerPoint = tickValue / tickSize;
    double lots = riskAmount / (slDistance * valuePerPoint);

    double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

    lots = MathMax(minLot, MathMin(maxLot, lots));
    lots = MathFloor(lots / lotStep) * lotStep;
    lots = NormalizeDouble(lots, 2);

    return lots;
}

//+------------------------------------------------------------------+
//| Open a trade and journal it                                     |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType, double lots, double sl, double tp, string reason)
{
    bool result = false;

    if(orderType == ORDER_TYPE_BUY)
        result = Trade.Buy(lots, Symbol(), 0, sl, tp, reason);
    else
        result = Trade.Sell(lots, Symbol(), 0, sl, tp, reason);

    if(result)
    {
        g_tradesToday++;
        ulong ticket = Trade.ResultOrder();
        double entryPrice = Trade.ResultPrice();
        LogTrade(ticket, orderType, lots, entryPrice, sl, tp, reason, "OPENED");
        Print("Trade opened: ", EnumToString(orderType), " Lots=", lots,
              " SL=", sl, " TP=", tp, " Reason=", reason);
    }
    else
    {
        Print("Failed to open trade. Error: ", Trade.ResultRetcode(),
              " - ", Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Update peak balance and count wins from closed positions        |
//+------------------------------------------------------------------+
void UpdatePerformance()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance > g_peakBalance) g_peakBalance = balance;

    // Count recently closed deals
    HistorySelect(TimeCurrent() - HISTORY_LOOKBACK_SECS, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins  = 0;
    int count = 0;

    for(int i = total - 1; i >= 0 && count < InpOptimizeTrades; i--)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != EA_MAGIC) continue;
        if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)       continue;

        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
        if(profit > 0) wins++;
        count++;
    }

    g_totalTrades   = count;
    g_winningTrades = wins;
}

//+------------------------------------------------------------------+
//| Reduce risk and enter optimize mode                             |
//+------------------------------------------------------------------+
void ActivateOptimizeMode(string reason)
{
    g_optimizeMode   = true;
    g_currentRiskPct = InpRiskPercent * InpRiskReductionFactor;
    Print(reason, " Reducing risk to ", g_currentRiskPct, "%.");
}

//+------------------------------------------------------------------+
//| Adjust risk if performance thresholds are breached              |
//+------------------------------------------------------------------+
void CheckOptimization()
{
    // Drawdown check
    if(g_peakBalance > 0.0)
    {
        double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
        double ddPct    = ((g_peakBalance - balance) / g_peakBalance) * 100.0;

        if(ddPct >= InpMaxDrawdownPct && !g_optimizeMode)
        {
            ActivateOptimizeMode(StringFormat("Drawdown=%.2f%% reached.", ddPct));
        }
        else if(ddPct < InpMaxDrawdownPct * InpRiskReductionFactor && g_optimizeMode)
        {
            g_optimizeMode   = false;
            g_currentRiskPct = InpRiskPercent;
            Print("Drawdown recovered. Restoring risk to ", g_currentRiskPct, "%.");
        }
    }

    // Win rate check
    if(g_totalTrades >= InpOptimizeTrades)
    {
        double winRate = ((double)g_winningTrades / (double)g_totalTrades) * 100.0;
        if(winRate < InpMinWinRate && !g_optimizeMode)
        {
            ActivateOptimizeMode(StringFormat("Win rate=%.1f%% below threshold.", winRate));
        }
    }
}

//+------------------------------------------------------------------+
//| Initialize trade journal CSV file                               |
//+------------------------------------------------------------------+
void InitJournal()
{
    int fh = FileOpen(InpJournalFile, FILE_READ | FILE_CSV, ',');
    if(fh == INVALID_HANDLE)
    {
        // File doesn't exist, create with header
        fh = FileOpen(InpJournalFile, FILE_WRITE | FILE_CSV, ',');
        if(fh != INVALID_HANDLE)
        {
            FileWrite(fh, "DateTime", "Ticket", "Symbol", "Type", "Lots",
                      "EntryPrice", "SL", "TP", "Reason", "Status");
            FileClose(fh);
        }
    }
    else
    {
        FileClose(fh);
    }
}

//+------------------------------------------------------------------+
//| Log a trade entry to the journal CSV                            |
//+------------------------------------------------------------------+
void LogTrade(ulong ticket, ENUM_ORDER_TYPE orderType, double lots,
              double entryPrice, double sl, double tp,
              string reason, string status)
{
    int fh = FileOpen(InpJournalFile, FILE_WRITE | FILE_READ | FILE_CSV | FILE_SHARE_READ, ',');
    if(fh == INVALID_HANDLE)
    {
        Print("Could not open journal file: ", InpJournalFile);
        return;
    }

    FileSeek(fh, 0, SEEK_END);
    FileWrite(fh,
              TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
              (string)ticket,
              Symbol(),
              EnumToString(orderType),
              DoubleToString(lots, 2),
              DoubleToString(entryPrice, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
              DoubleToString(sl,         (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
              DoubleToString(tp,         (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
              reason,
              status);
    FileClose(fh);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction: log closed positions with result            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(HistoryDealSelect(dealTicket))
    {
        long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
        if(magic != EA_MAGIC) return;

        long   entryType  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
        if(entryType != DEAL_ENTRY_OUT) return;

        double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
        double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
        long   orderType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
        double lots       = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

        string status = (profit >= 0) ? "WIN" : "LOSS";
        string reason = StringFormat("Closed. Profit=%.2f", profit);

        ENUM_ORDER_TYPE oType = (orderType == DEAL_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

        LogTrade(dealTicket, oType, lots, closePrice, 0, 0, reason, status);
        Print("Trade closed: Ticket=", dealTicket, " Profit=", profit, " Status=", status);
    }
}
//+------------------------------------------------------------------+
