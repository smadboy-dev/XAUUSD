//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.1;      // Trade Lot Size
input int      InpSwingLookback = 30;       // Bars to find Swing High/Low
input int      InpFVGMinSize    = 250;      // Minimum FVG size in Points
input int      InpTakeProfitPts = 5000;     // Target Profit in Points
input int      InpMagicNum      = 555666;   // Magic Number
input int      InpStartHour     = 12;       // London/NY Overlap Start
input int      InpEndHour       = 18;       // overlap End
input double   InpBodyMulti     = 2.0;      // Displacement Body Multiplier
input double   InpVolumeMulti   = 1.3;      // Displacement Volume Multiplier
input bool     InpUseVolumeProg = false;    // Require Increasing Volume on MSS
input bool     InpUseVWAP       = true;     // Use VWAP as Value Filter
input ENUM_TIMEFRAMES InpHTF    = PERIOD_H4;// Trend Timeframe
input ENUM_TIMEFRAMES InpLTF    = PERIOD_M15;// Execution Timeframe

//--- Global variables
CTrade   trade;
int      handleHTF_EMA;
int      handleD1_EMA;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   handleHTF_EMA = iMA(_Symbol, InpHTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   handleD1_EMA  = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);

   if(handleHTF_EMA == INVALID_HANDLE || handleD1_EMA == INVALID_HANDLE) return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleHTF_EMA);
   IndicatorRelease(handleD1_EMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Session Filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   // Manage existing positions
   ManagePositions();

   //--- Process on New Bar of Execution TF (LTF)
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, InpLTF, 0);
   if(current_time == last_time) return;
   last_time = current_time;

   //--- 2. Dual-Trend Bias (H4 + D1)
   double htfEma[], d1Ema[];
   ArraySetAsSeries(htfEma, true);
   ArraySetAsSeries(d1Ema, true);
   if(CopyBuffer(handleHTF_EMA, 0, 0, 1, htfEma) < 1 || CopyBuffer(handleD1_EMA, 0, 0, 1, d1Ema) < 1) return;

   double htfClose = iClose(_Symbol, InpHTF, 1);
   double d1Close  = iClose(_Symbol, PERIOD_D1, 1);

   bool isBullishBias = (htfClose > htfEma[0]) && (d1Close > d1Ema[0]);
   bool isBearishBias = (htfClose < htfEma[0]) && (d1Close < d1Ema[0]);

   if(!isBullishBias && !isBearishBias) return;

   //--- 3. Detect Liquidity Sweeps on LTF
   int highestIndex = iHighest(_Symbol, InpLTF, MODE_HIGH, InpSwingLookback, 3);
   int lowestIndex  = iLowest(_Symbol, InpLTF, MODE_LOW, InpSwingLookback, 3);
   double swingHigh = iHigh(_Symbol, InpLTF, highestIndex);
   double swingLow  = iLow(_Symbol, InpLTF, lowestIndex);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpLTF, 0, 10, rates) < 10) return;

   // Displacement Quality Check (Body Size & Volume)
   double avgBody = 0;
   double avgVolume = 0;
   for(int i=4; i<10; i++)
   {
      avgBody += MathAbs(rates[i].close - rates[i].open);
      avgVolume += (double)rates[i].tick_volume;
   }
   avgBody /= 6.0;
   avgVolume /= 6.0;

   double currentBody = MathAbs(rates[1].close - rates[1].open);
   bool isStrongDisplacement = (currentBody > (avgBody * InpBodyMulti)) && (rates[1].tick_volume > (avgVolume * InpVolumeMulti));

   // Sweep Candle is rates[2] (Requires Volume Confirmation)
   bool sweepBullish = (rates[2].low < swingLow) && (rates[2].close > swingLow) && (rates[2].tick_volume > avgVolume);
   bool sweepBearish = (rates[2].high > swingHigh) && (rates[2].close < swingHigh) && (rates[2].tick_volume > avgVolume);

   //--- 4. Market Structure Shift (MSS) + FVG
   // Volume Progression: Displacement volume (rates[1]) must be greater than Setup volume (rates[2])
   bool volumeProgression = !InpUseVolumeProg || (rates[1].tick_volume > rates[2].tick_volume);

   bool mssBullish = sweepBullish && (rates[1].close > rates[2].high) && isStrongDisplacement && volumeProgression;
   bool mssBearish = sweepBearish && (rates[1].close < rates[2].low) && isStrongDisplacement && volumeProgression;

   bool isBullishFVG = (rates[1].low > rates[3].high) && (rates[1].low - rates[3].high > InpFVGMinSize * _Point);
   bool isBearishFVG = (rates[1].high < rates[3].low) && (rates[3].low - rates[1].high > InpFVGMinSize * _Point);

   //--- Check current positions
   if(AlreadyInTrade()) return;

   //--- 5. Entry Execution (50% retracement of the Displacement move)
   double vwap = InpUseVWAP ? GetDailyVWAP() : 0;
   bool bullishValue = !InpUseVWAP || (rates[1].close < vwap);
   bool bearishValue = !InpUseVWAP || (rates[1].close > vwap);

   if(isBullishBias && mssBullish && isBullishFVG && bullishValue)
   {
      double entryPrice = (rates[1].high + rates[1].low) / 2.0; // Mean threshold of displacement
      double sl = rates[2].low - 100 * _Point;
      double tp = entryPrice + InpTakeProfitPts * _Point;

      if(trade.BuyLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Ultimate Buy"))
         Print("Session Start: Institutional Buy Limit at ", entryPrice);
   }
   else if(isBearishBias && mssBearish && isBearishFVG && bearishValue)
   {
      double entryPrice = (rates[1].high + rates[1].low) / 2.0;
      double sl = rates[2].high + 100 * _Point;
      double tp = entryPrice - InpTakeProfitPts * _Point;

      if(trade.SellLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Ultimate Sell"))
         Print("Session Start: Institutional Sell Limit at ", entryPrice);
   }
}

//+------------------------------------------------------------------+
//| Manage Positions (Trailing / BE)                                 |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
         {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               double dist = currentPrice - openPrice;
               if(dist > 1500 * _Point && currentSL < openPrice)
                  trade.PositionModify(ticket, openPrice + 10 * _Point, PositionGetDouble(POSITION_TP));
            }
            else
            {
               double dist = openPrice - currentPrice;
               if(dist > 1500 * _Point && (currentSL > openPrice || currentSL == 0))
                  trade.PositionModify(ticket, openPrice - 10 * _Point, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if already in trade                                        |
//+------------------------------------------------------------------+
bool AlreadyInTrade()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum) return true;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNum) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get Daily VWAP                                                   |
//+------------------------------------------------------------------+
double GetDailyVWAP()
{
   MqlRates daily_rates[];
   ArraySetAsSeries(daily_rates, true);

   // Copy rates from the start of the day
   datetime startOfDay = iTime(_Symbol, PERIOD_D1, 0);
   int count = CopyRates(_Symbol, InpLTF, startOfDay, TimeCurrent(), daily_rates);

   if(count <= 0) return 0;

   double sumPV = 0;
   long sumV = 0;

   for(int i=0; i<count; i++)
   {
      double typicalPrice = (daily_rates[i].high + daily_rates[i].low + daily_rates[i].close) / 3.0;
      sumPV += typicalPrice * (double)daily_rates[i].tick_volume;
      sumV += daily_rates[i].tick_volume;
   }

   return (sumV > 0) ? (sumPV / (double)sumV) : 0;
}
//+------------------------------------------------------------------+
