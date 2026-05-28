//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "3.01"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.1;      // Trade Lot Size
input int      InpSwingLookback = 20;       // Bars to find Swing High/Low
input int      InpFVGMinSize    = 150;      // Minimum FVG size in Points
input int      InpStopLoss      = 1000;     // Fixed Stop Loss in Points
input int      InpTakeProfit    = 3000;     // Take Profit in Points
input int      InpMagicNum      = 333444;   // Magic Number
input ENUM_TIMEFRAMES InpHTF    = PERIOD_H4;// Higher Timeframe for Bias

//--- Global variables
CTrade   trade;
int      handleHTF_EMA;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   // Create handle once in OnInit
   handleHTF_EMA = iMA(_Symbol, InpHTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(handleHTF_EMA == INVALID_HANDLE) return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleHTF_EMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Process on New Bar only
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, _Period, 0);
   if(current_time == last_time) return;
   last_time = current_time;

   //--- 1. Get Higher Timeframe (HTF) Bias
   double htfEma[];
   ArraySetAsSeries(htfEma, true);
   if(CopyBuffer(handleHTF_EMA, 0, 0, 1, htfEma) < 1) return;

   double htfClose = iClose(_Symbol, InpHTF, 1);
   bool isBullishBias = htfClose > htfEma[0];
   bool isBearishBias = htfClose < htfEma[0];

   //--- 2. Detect Liquidity Sweeps
   // Use closed bars for swing detection to avoid repainting
   // Start from index 3 so the 'sweep' candle (index 2) doesn't include itself in the range
   int highestIndex = iHighest(_Symbol, _Period, MODE_HIGH, InpSwingLookback, 3);
   int lowestIndex  = iLowest(_Symbol, _Period, MODE_LOW, InpSwingLookback, 3);
   double swingHigh = iHigh(_Symbol, _Period, highestIndex);
   double swingLow  = iLow(_Symbol, _Period, lowestIndex);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, 10, rates) < 10) return;

   // A Sweep occurs if bar 2 pierced the swing level but closed back
   // Signal candle is bar 1 (the displacement candle)
   bool sweepBullish = (rates[2].low < swingLow) && (rates[2].close > swingLow);
   bool sweepBearish = (rates[2].high > swingHigh) && (rates[2].close < swingHigh);

   //--- 3. Identify Displacement and FVG
   // FVG logic: check imbalance between candle 1 and candle 3
   bool isBullishFVG = (rates[1].low > rates[3].high) && (rates[1].low - rates[3].high > InpFVGMinSize * _Point);
   bool isBearishFVG = (rates[1].high < rates[3].low) && (rates[2].low - rates[0].high > InpFVGMinSize * _Point);
   // Wait, fixed a typo in BearishFVG above: rates[2].low -> rates[3].low and rates[0].high -> rates[1].high
   isBearishFVG = (rates[1].high < rates[3].low) && (rates[3].low - rates[1].high > InpFVGMinSize * _Point);

   //--- 4. Market Structure Shift (MSS)
   // MSS: Displacement candle (bar 1) breaks the high/low of the candle before the sweep (bar 2)
   bool mssBullish = sweepBullish && (rates[1].close > rates[2].high);
   bool mssBearish = sweepBearish && (rates[1].close < rates[2].low);

   //--- Check current positions
   if(AlreadyInTrade()) return;

   //--- 5. Entry Execution
   if(isBullishBias && mssBullish && isBullishFVG)
   {
      double entryPrice = rates[3].high; // Entry at the FVG gap start (institutional retest)
      double sl = entryPrice - InpStopLoss * _Point;
      double tp = entryPrice + InpTakeProfit * _Point;

      // Fix BuyLimit parameters
      if(trade.BuyLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Bullish Entry"))
         Print("HTF Bullish Bias: SMC Entry placed at ", entryPrice);
   }
   else if(isBearishBias && mssBearish && isBearishFVG)
   {
      double entryPrice = rates[3].low; // Entry at the FVG gap start (institutional retest)
      double sl = entryPrice + InpStopLoss * _Point;
      double tp = entryPrice - InpTakeProfit * _Point;

      // Fix SellLimit parameters
      if(trade.SellLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Bearish Entry"))
         Print("HTF Bearish Bias: SMC Entry placed at ", entryPrice);
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
