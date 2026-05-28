//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.1;      // Trade Lot Size
input int      InpFVGMinSize    = 100;      // Minimum FVG size in Points
input int      InpStopLoss      = 1500;     // Max Stop Loss in Points
input int      InpTakeProfit    = 3000;     // Take Profit in Points
input int      InpMagicNum      = 222333;   // Magic Number
input int      InpVolumeMulti   = 2;        // Displacement Volume Multiplier

//--- Global variables
CTrade   trade;

struct FVG_Data
{
   double start;
   double end;
   bool   isBullish;
   int    index;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   return(INIT_SUCCEEDED);
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

   //--- Identify Fair Value Gaps (FVG) and Displacement
   // We look at the last 3 closed candles (indices 1, 2, 3)
   // A Bullish FVG occurs when Low[1] > High[3]
   // A Bearish FVG occurs when High[1] < Low[3]

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, 10, rates) < 10) return;

   // Check for Displacement (Large Body + High Volume)
   double avgVolume = 0;
   for(int i=4; i<10; i++) avgVolume += (double)rates[i].tick_volume;
   avgVolume /= 6;

   bool isDisplacement = (double)rates[2].tick_volume > (avgVolume * InpVolumeMulti);

   // FVG Check
   bool isBullishFVG = (rates[1].low > rates[3].high) && (rates[1].low - rates[3].high > InpFVGMinSize * _Point);
   bool isBearishFVG = (rates[1].high < rates[3].low) && (rates[3].low - rates[1].high > InpFVGMinSize * _Point);

   // Market Structure Shift (MSS) simplified: Displacement must break recent high/low
   bool isBullishMSS = isBullishFVG && (rates[2].close > rates[4].high);
   bool isBearishMSS = isBearishFVG && (rates[2].close < rates[4].low);

   //--- Check current positions
   if(AlreadyInTrade()) return;

   if(isBullishMSS && isDisplacement)
   {
      // Buy Entry at the start of the Bullish FVG (the High of the 3rd candle)
      double entryPrice = rates[3].high;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(currentPrice > entryPrice) // Entry on retracement
      {
         double sl = entryPrice - InpStopLoss * _Point;
         double tp = entryPrice + InpTakeProfit * _Point;

         if(trade.BuyLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits)))
         {
            Print("Bullish Institutional Entry (FVG) placed at: ", entryPrice);
         }
      }
   }
   else if(isBearishMSS && isDisplacement)
   {
      // Sell Entry at the start of the Bearish FVG (the Low of the 3rd candle)
      double entryPrice = rates[3].low;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(currentPrice < entryPrice) // Entry on retracement
      {
         double sl = entryPrice + InpStopLoss * _Point;
         double tp = entryPrice - InpTakeProfit * _Point;

         if(trade.SellLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits)))
         {
            Print("Bearish Institutional Entry (FVG) placed at: ", entryPrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if already in trade                                        |
//+------------------------------------------------------------------+
bool AlreadyInTrade()
{
   // Check Positions
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum) return true;
      }
   }
   // Check Pending Orders
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
      {
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNum) return true;
      }
   }
   return false;
}
//+------------------------------------------------------------------+
