//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "18.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.01;     // Trade Lot Size
input int      InpSwingLookback = 50;       // Bars to find Swing High/Low
input double   InpTargetRR      = 3.0;      // Target Risk:Reward Ratio
input int      InpMagicNum      = 888999;   // Alpha Magic Number
input int      InpMaxTradesDay  = 1;        // High Quality Only: 1 per day
input int      InpFridayCloseHour = 22;     // Friday Session Close Hour (MSK)
input int      InpAsianStart    = 1;        // Asian Session Start (MSK)
input int      InpAsianEnd      = 10;       // Asian Session End (MSK)
input double   InpVolumeMulti   = 2.0;      // Climax Volume Multiplier (>2x avg)
input int      InpMaxSpread     = 40;       // Max Spread in Points ($0.40)
input int      InpATRPeriod     = 14;       // ATR Period for Volatility
input ENUM_TIMEFRAMES InpHTF    = PERIOD_H4;// Structural Timeframe
input ENUM_TIMEFRAMES InpLTF    = PERIOD_M15;// Execution Timeframe

//--- Global variables
CTrade   trade;
int      handleATR;
int      tradesToday = 0;
datetime lastTradeDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   handleATR = iATR(_Symbol, InpLTF, InpATRPeriod);

   if(handleATR == INVALID_HANDLE) return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   // 1. Reset Daily Trade Counter
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != lastTradeDay)
   {
      tradesToday = 0;
      lastTradeDay = today;
   }

   // 2. Friday Exit Logic
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
   {
      CloseAllTrades();
      return;
   }

   // 3. Killzone & Trade Limit Filter (MSK Time)
   // London: 11:00-13:00 | NY: 15:30-19:30
   bool inKillzone = (dt.hour >= 11 && dt.hour < 13) ||
                    (dt.hour == 15 && dt.min >= 30) ||
                    (dt.hour > 15 && dt.hour < 19) ||
                    (dt.hour == 19 && dt.min <= 30);

   if(!inKillzone || tradesToday >= InpMaxTradesDay) return;

   // 4. Spread Filter
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   // Manage existing positions
   ManagePositions();

   //--- Process on New Bar
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, InpLTF, 0);
   if(current_time == last_time) return;
   last_time = current_time;

   //--- 5. HTF Structural Bias (H4) - HH/HL or LH/LL
   // Check last 3 H4 bars for structural flow
   double h4_h1 = iHigh(_Symbol, InpHTF, 1);
   double h4_l1 = iLow(_Symbol, InpHTF, 1);
   double h4_h2 = iHigh(_Symbol, InpHTF, 2);
   double h4_l2 = iLow(_Symbol, InpHTF, 2);
   double h4_h3 = iHigh(_Symbol, InpHTF, 3);
   double h4_l3 = iLow(_Symbol, InpHTF, 3);

   bool isBullishBias = (h4_h1 > h4_h2 && h4_l1 > h4_l2) || (h4_h2 > h4_h3 && h4_l2 > h4_l3);
   bool isBearishBias = (h4_h1 < h4_h2 && h4_l1 < h4_l2) || (h4_h2 < h4_h3 && h4_l2 < h4_l3);

   //--- 6. Detect Liquidity Sweeps (Tiered)
   double pdh = iHigh(_Symbol, PERIOD_D1, 1);
   double pdl = iLow(_Symbol, PERIOD_D1, 1);

   double asianHigh = 0, asianLow = 0;
   int barsInDay = iBarShift(_Symbol, InpLTF, iTime(_Symbol, PERIOD_D1, 0));
   for(int i = barsInDay; i >= 0; i--)
   {
      MqlDateTime mTime; TimeToStruct(iTime(_Symbol, InpLTF, i), mTime);
      if(mTime.hour >= InpAsianStart && mTime.hour < InpAsianEnd)
      {
         double h = iHigh(_Symbol, InpLTF, i);
         double l = iLow(_Symbol, InpLTF, i);
         if(asianHigh == 0 || h > asianHigh) asianHigh = h;
         if(asianLow == 0 || l < asianLow) asianLow = l;
      }
   }

   MqlRates rates[]; ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpLTF, 0, 10, rates) < 10) return;

   double upperLiq = pdh; string upName = "PDH";
   if(asianHigh > 0 && MathAbs(rates[0].close - asianHigh) < MathAbs(rates[0].close - upperLiq)) { upperLiq = asianHigh; upName = "Asian High"; }

   double lowerLiq = pdl; string lowName = "PDL";
   if(asianLow > 0 && MathAbs(rates[0].close - asianLow) < MathAbs(rates[0].close - lowerLiq)) { lowerLiq = asianLow; lowName = "Asian Low"; }

   // ATR Volatility
   double atrBuffer[]; ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(handleATR, 0, 1, 20, atrBuffer) < 20) return;
   double curATR = atrBuffer[0];
   double sumATR = 0; for(int i=0; i<20; i++) sumATR += atrBuffer[i];
   double avgATR = sumATR / 20.0;

   // ATR Spike Filter (News Protection)
   if(curATR > 2.5 * avgATR) return;

   // 7. Volume Climax Displacement
   double avgVol = 0; for(int i=3; i<23; i++) avgVol += (double)rates[i].tick_volume;
   avgVol /= 20.0;

   double body1 = MathAbs(rates[1].close - rates[1].open);
   // Displacement must have climax volume and significant body relative to volatility
   bool isClimax = (rates[1].tick_volume > avgVol * InpVolumeMulti) && (body1 > curATR * 0.5);

   // Rejection Sweep (Wick ratio check)
   double candleSize2 = rates[2].high - rates[2].low;
   double upperWick2 = rates[2].high - MathMax(rates[2].open, rates[2].close);
   double lowerWick2 = MathMin(rates[2].open, rates[2].close) - rates[2].low;

   bool sweepBullish = (rates[2].low < lowerLiq) && (rates[2].close > lowerLiq) && (candleSize2 > 0 && lowerWick2/candleSize2 > 0.3);
   bool sweepBearish = (rates[2].high > upperLiq) && (rates[2].close < upperLiq) && (candleSize2 > 0 && upperWick2/candleSize2 > 0.3);

   if(AlreadyInTrade()) return;

   // 8. Execution
   if(sweepBullish && rates[1].close > rates[2].high && isClimax && isBullishBias)
   {
      double entry = (rates[2].high + rates[2].low) / 2.0; // Mean Threshold Entry
      double sl = rates[2].low - 50 * _Point; // 50 point buffer
      double tp = entry + (MathAbs(entry-sl) * InpTargetRR);
      if(trade.BuyLimit(InpLotSize, NormalizeDouble(entry, _Digits), _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "Institutional Alpha"))
      {
         Print("Alpha Buy: ", lowName, " Sweep | Vol Climax: ", rates[1].tick_volume);
         tradesToday++;
      }
   }
   if(sweepBearish && rates[1].close < rates[2].low && isClimax && isBearishBias)
   {
      double entry = (rates[2].high + rates[2].low) / 2.0; // Mean Threshold Entry
      double sl = rates[2].high + 50 * _Point; // 50 point buffer
      double tp = entry - (MathAbs(sl-entry) * InpTargetRR);
      if(trade.SellLimit(InpLotSize, NormalizeDouble(entry, _Digits), _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "Institutional Alpha"))
      {
         Print("Alpha Sell: ", upName, " Sweep | Vol Climax: ", rates[1].tick_volume);
         tradesToday++;
      }
   }
}

void ManagePositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
      {
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double cur = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double risk = MathAbs(open - sl);
         double profit = MathAbs(cur - open);

         // Breakeven at 1.5R
         if(risk > 0 && profit > risk * 1.5)
         {
            double nsl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open + 20 * _Point : open - 20 * _Point;
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && sl < open) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > open || sl == 0)))
            {
               trade.PositionModify(t, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

void CloseAllTrades()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
         trade.PositionClose(PositionGetTicket(i));
   }
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(OrderSelect(OrderGetTicket(i)) && OrderGetInteger(ORDER_MAGIC) == InpMagicNum)
         trade.OrderDelete(OrderGetTicket(i));
   }
}

bool AlreadyInTrade()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) return true;
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(OrderGetTicket(i)) && OrderGetInteger(ORDER_MAGIC) == InpMagicNum) return true;
   return false;
}
