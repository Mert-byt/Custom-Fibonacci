//+------------------------------------------------------------------+
//|                                                 DarkBird.mq5     |
//|        Multi-entry scalping EA with adaptive risk management     |
//+------------------------------------------------------------------+
#property copyright   "DarkBird"
#property version     "1.00"
#property description "Scalping EA: EMA trend + RSI momentum + Bollinger midline reclaim"
#property description "ATR stops, %-equity sizing, BE, trailing, early exits, daily loss guard"

#include <Trade\Trade.mqh>

//============================== INPUTS ==============================
input group "=== Risk Management ==="
input double InpRiskPercent        = 1.0;   // Risk per trade (% of equity)
input double InpMaxDailyLossPct    = 3.0;   // Halt new entries after daily loss X% (0=off)
input double InpMaxOpenRiskPct     = 4.0;   // Cap on total open risk (% equity, 0=off)
input int    InpMaxSpreadPoints    = 25;    // Max spread to allow entries (points)
input int    InpSlippagePoints     = 10;    // Max execution deviation (points)
input int    InpMaxPosPerDirection = 3;     // Max simultaneous positions per direction
input int    InpMaxTotalPositions  = 6;     // Max simultaneous positions overall
input int    InpMinEntryStepPoints = 150;   // Min distance between same-direction entries (points)
input int    InpEntryCooldownSec   = 30;    // Cooldown between entries per direction (sec)

input group "=== Stop Loss / Take Profit ==="
input bool   InpUseATRStops   = true;       // true: ATR-based stops | false: fixed points
input int    InpATRPeriod     = 14;         // ATR period
input double InpSL_AtrMult    = 1.5;        // SL distance = ATR * this
input double InpTP_AtrMult    = 2.5;        // TP distance = ATR * this
input int    InpFixedSLPoints = 200;        // Fixed SL (points) when ATR stops off
input int    InpFixedTPPoints = 300;        // Fixed TP (points) when ATR stops off

input group "=== Adaptive Trade Management ==="
input int  InpBETriggerPoints = 120;        // Profit (points) to move SL to breakeven (0=off)
input int  InpBEOffsetPoints  = 20;         // Breakeven lock-in offset (points)
input bool InpUseTrailing     = true;       // Enable trailing stop
input int  InpTrailPoints     = 150;        // Trailing distance (points)
input int  InpTrailStepPoints = 30;         // Min improvement before moving SL again (points)
input int  InpMaxTradeSec     = 0;          // Time-stop: close losing trades older than X sec (0=off)
input bool InpExitOnSignal    = true;       // Early exit on adverse indicator signal

input group "=== Indicators (current timeframe) ==="
input int    InpFastEMA  = 9;               // Fast EMA period
input int    InpSlowEMA  = 21;              // Slow EMA period
input int    InpRSIPeriod= 14;              // RSI period
input double InpRSI_OB   = 70.0;            // Do NOT buy above this RSI
input double InpRSI_OS   = 30.0;            // Do NOT sell below this RSI
input int    InpBBPeriod = 20;              // Bollinger period
input double InpBBDev    = 2.0;             // Bollinger deviation

input group "=== Session Filter (server time) ==="
input bool InpUseTimeFilter = false;        // Restrict trading hours
input int  InpStartHour     = 8;            // Session start hour
input int  InpEndHour       = 20;           // Session end hour

input group "=== Identification ==="
input ulong InpMagic = 20260731;            // Magic number

//============================== GLOBALS =============================
CTrade   trade;

int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE, hBB   = INVALID_HANDLE, hATR = INVALID_HANDLE;

double   gFast[], gSlow[], gRSI[], gAtr[];
double   gBBup[], gBBmid[], gBBlow[];
MqlRates gRates[];

datetime gLastBuyTime  = 0, gLastSellTime = 0;   // entry cooldown timers
int      gDayId        = -1;                     // current day id for daily reset
double   gDayStartEq   = 0.0;                    // equity at start of day
uint     gLastStatusMs = 0;                      // dashboard throttle

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- sanity checks on parameters
   if(InpFastEMA >= InpSlowEMA)
   {  Print("INIT ERROR: Fast EMA must be < Slow EMA."); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 20.0)
   {  Print("INIT ERROR: RiskPercent out of sane range."); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxPosPerDirection < 1 || InpMaxTotalPositions < 1)
   {  Print("INIT ERROR: Position limits must be >= 1."); return INIT_PARAMETERS_INCORRECT; }

   //--- indicator handles (current timeframe -> works on whatever chart attached)
   hFast = iMA(_Symbol, PERIOD_CURRENT, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_CURRENT, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
   hBB   = iBands(_Symbol, PERIOD_CURRENT, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hRSI==INVALID_HANDLE ||
      hBB==INVALID_HANDLE   || hATR==INVALID_HANDLE)
   {  Print("INIT ERROR: Failed to create indicator handles."); return INIT_FAILED; }

   //--- trade object configuration: magic, slippage, broker filling mode
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);          // auto-detect FOK/IOC/RETURN
   trade.SetAsyncMode(false);                      // synchronous = deterministic for scalping

   //--- series indexing (index 0 = latest)
   ArraySetAsSeries(gFast,true);  ArraySetAsSeries(gSlow,true);
   ArraySetAsSeries(gRSI,true);   ArraySetAsSeries(gAtr,true);
   ArraySetAsSeries(gBBup,true);  ArraySetAsSeries(gBBmid,true);
   ArraySetAsSeries(gBBlow,true); ArraySetAsSeries(gRates,true);

   //--- daily-loss baseline
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   gDayId      = dt.year * 1000 + dt.day_of_year;
   gDayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- informational: pyramiding needs a hedging account to keep tickets separate
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("NOTE: Netting account detected. Multiple same-direction entries will merge into one net position.");

   Print("DarkBird initialized on ", _Symbol, " ", EnumToString(Period()));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFast); IndicatorRelease(hSlow);
   IndicatorRelease(hRSI);  IndicatorRelease(hBB); IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- environment gates (fast fail, no work if we can't trade)
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))            return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))                  return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))          return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))           return;
   if(!RefreshData())                                      return;   // indicators not ready

   RollDayIfNeeded();

   //--- adaptive management runs EVERY tick: exits, BE, trailing (speed matters)
   ManageOpenPositions();

   int sig = GetSignal();

   //--- entry gates
   if(!DailyLossLimitHit() && SpreadOK() && SessionOK())
      TryEntries(sig);

   UpdateDashboard(sig);
}

//+------------------------------------------------------------------+
//| Copy latest indicator values. Returns false if data not ready.   |
//+------------------------------------------------------------------+
bool RefreshData()
{
   if(BarsCalculated(hSlow) < InpSlowEMA + 2) return false;   // warmup
   if(BarsCalculated(hBB)   < InpBBPeriod + 2) return false;

   if(CopyBuffer(hFast, 0, 0, 3, gFast)  < 3) return false;
   if(CopyBuffer(hSlow, 0, 0, 3, gSlow)  < 3) return false;
   if(CopyBuffer(hRSI,  0, 0, 3, gRSI)   < 3) return false;
   if(CopyBuffer(hATR,  0, 0, 2, gAtr)   < 2) return false;
   if(CopyBuffer(hBB, UPPER_BAND, 0, 3, gBBup)  < 3) return false;
   if(CopyBuffer(hBB, BASE_LINE,  0, 3, gBBmid) < 3) return false;
   if(CopyBuffer(hBB, LOWER_BAND, 0, 3, gBBlow) < 3) return false;
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, gRates) < 3)   return false;
   return true;
}

//+------------------------------------------------------------------+
//| Signal engine                                                    |
//|  BUY : uptrend + RSI rising in 50..OB + pullback to BB midline   |
//|        on the last closed bar with live price back above it      |
//|  SELL: mirror                                                    |
//+------------------------------------------------------------------+
int GetSignal()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool bullTrend = (gFast[0] > gSlow[0]);
   bool bearTrend = (gFast[0] < gSlow[0]);

   //--- BUY setup
   bool buyMomentum = (gRSI[0] > 50.0 && gRSI[0] >= gRSI[1] && gRSI[0] < InpRSI_OB);
   bool buyTrigger  = (gRates[1].low <= gBBmid[1])        // pullback touched midline
                   && (ask > gBBmid[0])                   // live price reclaimed it
                   && (gRates[1].close > gBBlow[1]);      // no lower-band breakdown
   if(bullTrend && buyMomentum && buyTrigger) return +1;

   //--- SELL setup (mirror)
   bool sellMomentum = (gRSI[0] < 50.0 && gRSI[0] <= gRSI[1] && gRSI[0] > InpRSI_OS);
   bool sellTrigger  = (gRates[1].high >= gBBmid[1])
                   && (bid < gBBmid[0])
                   && (gRates[1].close < gBBup[1]);
   if(bearTrend && sellMomentum && sellTrigger) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Entry dispatcher with pyramiding controls                        |
//+------------------------------------------------------------------+
void TryEntries(const int sig)
{
   if(sig == 0) return;
   if(CountPositions(-1) >= InpMaxTotalPositions) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(sig == +1)
   {
      if(CountPositions(POSITION_TYPE_SELL) > 0)                 return; // no simultaneous opposite book
      if(CountPositions(POSITION_TYPE_BUY) >= InpMaxPosPerDirection) return;
      if(TimeCurrent() - gLastBuyTime < InpEntryCooldownSec)     return; // cooldown
      double last = LastEntryPrice(POSITION_TYPE_BUY);
      if(last > 0.0 && MathAbs(ask - last) < InpMinEntryStepPoints * _Point) return; // anti-cluster
      if(OpenTrade(ORDER_TYPE_BUY)) gLastBuyTime = TimeCurrent();
   }
   else if(sig == -1)
   {
      if(CountPositions(POSITION_TYPE_BUY) > 0)                  return;
      if(CountPositions(POSITION_TYPE_SELL) >= InpMaxPosPerDirection) return;
      if(TimeCurrent() - gLastSellTime < InpEntryCooldownSec)    return;
      double last = LastEntryPrice(POSITION_TYPE_SELL);
      if(last > 0.0 && MathAbs(bid - last) < InpMinEntryStepPoints * _Point) return;
      if(OpenTrade(ORDER_TYPE_SELL)) gLastSellTime = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Compute SL/TP distances (ATR-adaptive or fixed)                  |
//+------------------------------------------------------------------+
double StopDistance()   { return (InpUseATRStops && gAtr[0] > 0.0) ? InpSL_AtrMult * gAtr[0]
                                                                   : InpFixedSLPoints * _Point; }
double TargetDistance() { return (InpUseATRStops && gAtr[0] > 0.0) ? InpTP_AtrMult * gAtr[0]
                                                                   : InpFixedTPPoints * _Point; }

//+------------------------------------------------------------------+
//| Execute a market order with SL/TP, retries and risk budget check |
//+------------------------------------------------------------------+
bool OpenTrade(const ENUM_ORDER_TYPE type)
{
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- respect broker minimum stop distance
   long   stopsPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = (stopsPts + 2) * _Point;
   double slDist   = MathMax(StopDistance(),   minDist);
   double tpDist   = MathMax(TargetDistance(), minDist);

   double sl, tp;
   if(type == ORDER_TYPE_BUY) { sl = NormalizeDouble(price - slDist, _Digits);
                                tp = NormalizeDouble(price + tpDist, _Digits); }
   else                       { sl = NormalizeDouble(price + slDist, _Digits);
                                tp = NormalizeDouble(price - tpDist, _Digits); }

   double lots = CalcVolume(type, price, sl);
   if(lots <= 0.0) return false;

   if(!OpenRiskBudgetOK(type, price, sl, lots)) return false;   // aggregate risk cap

   string cmt = (type == ORDER_TYPE_BUY) ? "Dbird BUY" : "Dbird SELL";

   //--- retry loop for requotes / transient rejects
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      bool sent = (type == ORDER_TYPE_BUY) ? trade.Buy (lots, _Symbol, 0.0, sl, tp, cmt)
                                           : trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      {
         PrintFormat("OPEN %s %.2f lots @ %s | SL=%s TP=%s",
                     cmt, lots, DoubleToString(price, _Digits),
                     DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
         return true;
      }
      PrintFormat("Order attempt %d failed: retcode=%u (%s)", attempt, rc,
                  trade.ResultRetcodeDescription());
      Sleep(300);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Position sizing: risk InpRiskPercent% of equity to the SL.       |
//| Uses OrderCalcProfit (exact, account-currency) with tick fallback|
//+------------------------------------------------------------------+
double CalcVolume(const ENUM_ORDER_TYPE type, const double openPrice, const double slPrice)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double lossOneLot = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, openPrice, slPrice, lossOneLot) || lossOneLot >= 0.0)
   {
      //--- fallback: tick value method
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0.0 || ts <= 0.0) return 0.0;
      lossOneLot = -(MathAbs(openPrice - slPrice) / ts) * tv;
   }

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   double raw = riskMoney / MathAbs(lossOneLot);

   //--- safety: if even the minimum lot risks > 2x intended risk, skip the trade
   if(raw < minV && MathAbs(lossOneLot) * minV > riskMoney * 2.0)
   {  Print("Skip: minimum lot exceeds acceptable risk."); return 0.0; }

   double lots = MathFloor(raw / step + 1e-9) * step;         // round DOWN to step
   lots = MathMin(MathMax(lots, minV), maxV);
   lots = NormalizeDouble(lots, 8);

   //--- margin availability check
   double need = 0.0;
   if(OrderCalcMargin(type, _Symbol, lots, openPrice, need))
   {
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(need > free * 0.9)
      {  Print("Skip: insufficient free margin."); return 0.0; }
   }
   return lots;
}

//+------------------------------------------------------------------+
//| Aggregate open-risk budget check (sum of worst-case losses)      |
//+------------------------------------------------------------------+
bool OpenRiskBudgetOK(const ENUM_ORDER_TYPE type, const double openPrice,
                      const double slPrice, const double lots)
{
   if(InpMaxOpenRiskPct <= 0.0) return true;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double used   = 0.0, p = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)        continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      double psl = PositionGetDouble(POSITION_SL);
      if(psl == 0.0) continue;
      if(OrderCalcProfit((ENUM_ORDER_TYPE)PositionGetInteger(POSITION_TYPE), _Symbol,
                         PositionGetDouble(POSITION_VOLUME),
                         PositionGetDouble(POSITION_PRICE_OPEN), psl, p) && p < 0.0)
         used += -p;
   }
   double add = 0.0;
   if(OrderCalcProfit(type, _Symbol, lots, openPrice, slPrice, p) && p < 0.0) add = -p;

   return (used + add) <= equity * InpMaxOpenRiskPct / 100.0;
}

//+------------------------------------------------------------------+
//| Per-tick management of every EA position:                        |
//|  1) time-stop  2) adverse-signal early exit  3) BE  4) trailing  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop    = (stopsLevel + 2) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);          // selects the position
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool     isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl     = PositionGetDouble(POSITION_SL);
      double   tp     = PositionGetDouble(POSITION_TP);
      datetime tOpen  = (datetime)PositionGetInteger(POSITION_TIME);
      double   cur    = isBuy ? bid : ask;
      double   profitPts = isBuy ? (cur - open) / _Point : (open - cur) / _Point;

      //--- 1) time-stop: scalp that never worked -> cut it
      if(InpMaxTradeSec > 0 && (TimeCurrent() - tOpen) >= InpMaxTradeSec && profitPts < 0.0)
      { ClosePosition(ticket, "time-stop"); continue; }

      //--- 2) preemptive exit BEFORE the SL is hit when indicators turn
      if(InpExitOnSignal && AdverseSignal(isBuy))
      { ClosePosition(ticket, "adverse signal"); continue; }

      double targetSL = sl;

      //--- 3) break-even lock
      if(InpBETriggerPoints > 0 && profitPts >= InpBETriggerPoints)
      {
         double beSL = isBuy ? open + InpBEOffsetPoints * _Point
                             : open - InpBEOffsetPoints * _Point;
         if(isBuy  && (targetSL == 0.0 || targetSL < beSL)) targetSL = beSL;
         if(!isBuy && (targetSL == 0.0 || targetSL > beSL)) targetSL = beSL;
      }

      //--- 4) stepped trailing stop
      if(InpUseTrailing && InpTrailPoints > 0 &&
         profitPts >= InpTrailPoints + InpTrailStepPoints)
      {
         double tSL = isBuy ? cur - InpTrailPoints * _Point
                            : cur + InpTrailPoints * _Point;
         if(isBuy  && (targetSL == 0.0 || tSL > targetSL + InpTrailStepPoints * _Point)) targetSL = tSL;
         if(!isBuy && (targetSL == 0.0 || tSL < targetSL - InpTrailStepPoints * _Point)) targetSL = tSL;
      }

      //--- apply only a meaningful, broker-valid change
      if(MathAbs(targetSL - sl) < _Point) continue;
      if(isBuy  && targetSL > bid - minStop) continue;   // too close right now; retry next tick
      if(!isBuy && targetSL < ask + minStop) continue;

      if(!trade.PositionModify(ticket, NormalizeDouble(targetSL, _Digits), tp))
         PrintFormat("Modify #%I64u failed: %s", ticket, trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Adverse conditions for an open trade (preemptive loss avoidance) |
//+------------------------------------------------------------------+
bool AdverseSignal(const bool isBuy)
{
   if(isBuy)
      return (gFast[0] < gSlow[0])              // trend flipped
          || (gRSI[0] < 45.0)                   // momentum failure
          || (gRates[0].close < gBBlow[0]);     // lower-band breakdown
   else
      return (gFast[0] > gSlow[0])
          || (gRSI[0] > 55.0)
          || (gRates[0].close > gBBup[0]);
}

//+------------------------------------------------------------------+
//| Close with retries                                               |
//+------------------------------------------------------------------+
bool ClosePosition(const ulong ticket, const string reason)
{
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(trade.PositionClose(ticket))
      { PrintFormat("CLOSE #%I64u (%s)", ticket, reason); return true; }
      PrintFormat("Close attempt %d for #%I64u failed: %s",
                  attempt, ticket, trade.ResultRetcodeDescription());
      Sleep(200);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int CountPositions(const int ptype /* -1 = any */)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(ptype < 0 || (int)PositionGetInteger(POSITION_TYPE) == ptype) n++;
   }
   return n;
}

double LastEntryPrice(const int ptype)
{
   datetime newest = 0; double price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != ptype)       continue;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newest) { newest = t; price = PositionGetDouble(POSITION_PRICE_OPEN); }
   }
   return price;
}

bool SpreadOK()
{  return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints; }

bool SessionOK()
{
   if(!InpUseTimeFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);   // overnight window
}

void RollDayIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int id = dt.year * 1000 + dt.day_of_year;
   if(id != gDayId)
   {
      gDayId      = id;
      gDayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);   // new daily baseline
      Print("New trading day. Daily baseline equity = ", DoubleToString(gDayStartEq, 2));
   }
}

bool DailyLossLimitHit()
{
   if(InpMaxDailyLossPct <= 0.0) return false;
   bool hit = AccountInfoDouble(ACCOUNT_EQUITY) <=
              gDayStartEq * (1.0 - InpMaxDailyLossPct / 100.0);
   if(hit) Comment("Daily loss limit reached - new entries suspended (existing trades still managed).");
   return hit;
}

void UpdateDashboard(const int sig)
{
   if(GetTickCount() - gLastStatusMs < 500) return;           // throttle to 2 Hz
   gLastStatusMs = GetTickCount();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   string s = "===== DarkBird MT5 =====\n";
   s += StringFormat("Equity: %.2f | Spread: %d pts | Signal: %s\n",
                     eq, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
                     sig > 0 ? "BUY" : (sig < 0 ? "SELL" : "flat"));
   s += StringFormat("Positions: BUY %d / SELL %d | Daily P/L: %+.2f | RSI: %.1f | ATR: %s\n",
                     CountPositions(POSITION_TYPE_BUY), CountPositions(POSITION_TYPE_SELL),
                     eq - gDayStartEq, gRSI[0], DoubleToString(gAtr[0], _Digits));
   s += StringFormat("EMA %d/%d: %s trend\n", InpFastEMA, InpSlowEMA,
                     gFast[0] > gSlow[0] ? "UP" : (gFast[0] < gSlow[0] ? "DOWN" : "flat"));
   Comment(s);
}
//+------------------------------------------------------------------+