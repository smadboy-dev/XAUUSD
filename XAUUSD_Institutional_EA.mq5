//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "12.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.01;     // Trade Lot Size
input int      InpSwingLookback = 50;       // Bars to find Swing High/Low
input int      InpFVGMinSize    = 50;       // Minimum FVG size in Points ($0.50)
input int      InpTakeProfitPts = 2500;     // Target Profit in Points ($25.00)
input int      InpMagicNum      = 555666;   // Magic Number
input int      InpStartHour     = 11;       // London Start Hour (MSK)
input int      InpEndHour       = 21;       // NY End Hour (MSK)
input int      InpAsianStart    = 1;        // Asian Session Start (MSK)
input int      InpAsianEnd      = 10;       // Asian Session End (MSK)
input double   InpBodyMulti     = 1.2;      // Displacement Body Multiplier
input double   InpVolumeMulti   = 1.0;      // Displacement Volume Multiplier
input bool     InpUseVolumeProg = false;    // Require Increasing Volume on MSS
input bool     InpUseVWAP       = true;     // Use VWAP as Value Filter
input int      InpATRPeriod     = 14;       // ATR Period for Volatility
input double   InpATRMulti      = 1.0;      // Displacement ATR Multiplier
input ENUM_TIMEFRAMES InpHTF    = PERIOD_H4;// Trend Timeframe
input ENUM_TIMEFRAMES InpLTF    = PERIOD_M15;// Execution Timeframe

//--- Global variables
CTrade   trade;
int      handleHTF_EMA;
int      handleD1_EMA;
int      handleATR;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   handleHTF_EMA = iMA(_Symbol, InpHTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   handleD1_EMA  = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, InpLTF, InpATRPeriod);

   if(handleHTF_EMA == INVALID_HANDLE || handleD1_EMA == INVALID_HANDLE || handleATR == INVALID_HANDLE) return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleHTF_EMA);
   IndicatorRelease(handleD1_EMA);
   IndicatorRelease(handleATR);
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

   //--- 2. Trend Bias (H4)
   double htfEma[];
   ArraySetAsSeries(htfEma, true);
   if(CopyBuffer(handleHTF_EMA, 0, 0, 1, htfEma) < 1) return;

   double htfClose = iClose(_Symbol, InpHTF, 1);

   bool isBullishBias = (htfClose > htfEma[0]);
   bool isBearishBias = (htfClose < htfEma[0]);

   if(!isBullishBias && !isBearishBias) return;

   //--- 3. Detect Asian Range & Liquidity Sweeps
   double asianHigh = 0, asianLow = 0;
   int barsInDay = iBarShift(_Symbol, InpLTF, iTime(_Symbol, PERIOD_D1, 0));

   for(int i = barsInDay; i >= 0; i--)
   {
      datetime barTime = iTime(_Symbol, InpLTF, i);
      MqlDateTime mqlTime;
      TimeToStruct(barTime, mqlTime);

      if(mqlTime.hour >= InpAsianStart && mqlTime.hour < InpAsianEnd)
      {
         double high = iHigh(_Symbol, InpLTF, i);
         double low  = iLow(_Symbol, InpLTF, i);
         if(asianHigh == 0 || high > asianHigh) asianHigh = high;
         if(asianLow == 0 || low < asianLow) asianLow = low;
      }
   }

   int highestIndex = iHighest(_Symbol, InpLTF, MODE_HIGH, InpSwingLookback, 3);
   int lowestIndex  = iLowest(_Symbol, InpLTF, MODE_LOW, InpSwingLookback, 3);
   double swingHigh = iHigh(_Symbol, InpLTF, highestIndex);
   double swingLow  = iLow(_Symbol, InpLTF, lowestIndex);

   // Use Asian levels if available, otherwise use swing levels
   double upperLiquidity = (asianHigh > 0) ? asianHigh : swingHigh;
   double lowerLiquidity = (asianLow > 0) ? asianLow : swingLow;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpLTF, 0, 10, rates) < 10) return;

   // Get ATR for Volatility Filtering
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(handleATR, 0, 1, 1, atrBuffer) < 1) return;
   double currentATR = atrBuffer[0];

   // Displacement Quality Check (Body Size, Volume & Volatility)
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
   // Must exceed both average body AND current volatility (ATR)
   bool isStrongDisplacement = (currentBody > (avgBody * InpBodyMulti)) &&
                               (currentBody > (currentATR * InpATRMulti)) &&
                               (rates[1].tick_volume > (avgVolume * InpVolumeMulti));

   // Sweep Candle is rates[2] (Requires Volume & Rejection Wick)
   double candleSize2 = rates[2].high - rates[2].low;
   double lowerWick2 = (rates[2].open < rates[2].close) ? (rates[2].open - rates[2].low) : (rates[2].close - rates[2].low);
   double upperWick2 = (rates[2].open > rates[2].close) ? (rates[2].high - rates[2].open) : (rates[2].high - rates[2].close);

   bool hasLowerRejection = (candleSize2 > 0) && (lowerWick2 / candleSize2 > 0.2);
   bool hasUpperRejection = (candleSize2 > 0) && (upperWick2 / candleSize2 > 0.2);

   bool sweepBullish = (rates[2].low < lowerLiquidity) && (rates[2].close > lowerLiquidity) &&
                       (rates[2].tick_volume > avgVolume) && hasLowerRejection;
   bool sweepBearish = (rates[2].high > upperLiquidity) && (rates[2].close < upperLiquidity) &&
                       (rates[2].tick_volume > avgVolume) && hasUpperRejection;

   if(sweepBullish) Print("Diag: Bullish Sweep Detected at ", lowerLiquidity);
   if(sweepBearish) Print("Diag: Bearish Sweep Detected at ", upperLiquidity);

   //--- 4. Market Structure Shift (MSS) + FVG
   // Volume Progression: Displacement volume (rates[1]) must be greater than Setup volume (rates[2])
   bool volumeProgression = !InpUseVolumeProg || (rates[1].tick_volume > rates[2].tick_volume);

   bool mssBullish = sweepBullish && (rates[1].close > rates[2].high) && isStrongDisplacement && volumeProgression;
   bool mssBearish = sweepBearish && (rates[1].close < rates[2].low) && isStrongDisplacement && volumeProgression;

   if(sweepBullish && (rates[1].close > rates[2].high)) Print("Diag: Bullish MSS Candidate found. Displacement: ", isStrongDisplacement, " VolProg: ", volumeProgression);
   if(sweepBearish && (rates[1].close < rates[2].low)) Print("Diag: Bearish MSS Candidate found. Displacement: ", isStrongDisplacement, " VolProg: ", volumeProgression);

   bool isBullishFVG = (rates[1].low > rates[3].high) && (rates[1].low - rates[3].high > InpFVGMinSize * _Point);
   bool isBearishFVG = (rates[1].high < rates[3].low) && (rates[3].low - rates[1].high > InpFVGMinSize * _Point);

   //--- Check current positions
   if(AlreadyInTrade()) return;

   //--- 5. Entry Execution (50% retracement of the Displacement move)
   double vwap = InpUseVWAP ? GetDailyVWAP() : 0;
   bool bullishValue = !InpUseVWAP || (rates[1].close < vwap);
   bool bearishValue = !InpUseVWAP || (rates[1].close > vwap);

   if(mssBullish) Print("Diag: Bullish setup final check: Bias: ", isBullishBias, " FVG: ", isBullishFVG, " Value: ", bullishValue);
   if(mssBearish) Print("Diag: Bearish setup final check: Bias: ", isBearishBias, " FVG: ", isBearishFVG, " Value: ", bearishValue);

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
