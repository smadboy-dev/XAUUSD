//+------------------------------------------------------------------+
//|                                     XAUUSD_Institutional_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input double   InpLotSize       = 0.1;      // Trade Lot Size
input int      InpSwingLookback = 30;       // Bars to find Swing High/Low
input int      InpFVGMinSize    = 200;      // Minimum FVG size in Points
input int      InpTakeProfitPts = 4000;     // Fixed Take Profit in Points
input int      InpMagicNum      = 444555;   // Magic Number
input ENUM_TIMEFRAMES InpHTF    = PERIOD_H4;// Higher Timeframe for Bias
input ENUM_TIMEFRAMES InpLTF    = PERIOD_M15;// Execution Timeframe
input double   InpATRMultiplier = 1.5;      // ATR Multiplier for SL Buffer
input bool     InpUseBreakeven  = true;     // Move to BE at 1:1 RR

//--- Global variables
CTrade   trade;
int      handleHTF_EMA;
int      handleLTF_ATR;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   handleHTF_EMA = iMA(_Symbol, InpHTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   handleLTF_ATR = iATR(_Symbol, InpLTF, 14);

   if(handleHTF_EMA == INVALID_HANDLE || handleLTF_ATR == INVALID_HANDLE) return(INIT_FAILED);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleHTF_EMA);
   IndicatorRelease(handleLTF_ATR);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage existing positions (Breakeven logic)
   if(InpUseBreakeven) ManagePositions();

   //--- Process on New Bar of Execution TF (LTF)
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, InpLTF, 0);
   if(current_time == last_time) return;
   last_time = current_time;

   //--- 1. Get Higher Timeframe (HTF) Bias
   double htfEma[];
   ArraySetAsSeries(htfEma, true);
   if(CopyBuffer(handleHTF_EMA, 0, 0, 1, htfEma) < 1) return;

   double htfClose = iClose(_Symbol, InpHTF, 1);
   bool isBullishBias = htfClose > htfEma[0];
   bool isBearishBias = htfClose < htfEma[0];

   //--- 2. Detect Liquidity Sweeps on LTF
   int highestIndex = iHighest(_Symbol, InpLTF, MODE_HIGH, InpSwingLookback, 3);
   int lowestIndex  = iLowest(_Symbol, InpLTF, MODE_LOW, InpSwingLookback, 3);
   double swingHigh = iHigh(_Symbol, InpLTF, highestIndex);
   double swingLow  = iLow(_Symbol, InpLTF, lowestIndex);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpLTF, 0, 10, rates) < 10) return;

   // Sweep Candle is rates[2]
   bool sweepBullish = (rates[2].low < swingLow) && (rates[2].close > swingLow);
   bool sweepBearish = (rates[2].high > swingHigh) && (rates[2].close < swingHigh);

   //--- 3. Identify Displacement and FVG
   // Displacement Candle is rates[1]
   bool isBullishFVG = (rates[1].low > rates[3].high) && (rates[1].low - rates[3].high > InpFVGMinSize * _Point);
   bool isBearishFVG = (rates[1].high < rates[3].low) && (rates[3].low - rates[1].high > InpFVGMinSize * _Point);

   //--- 4. Market Structure Shift (MSS)
   // Displacement candle (bar 1) breaks the high/low of the candle before the sweep (bar 2)
   bool mssBullish = sweepBullish && (rates[1].close > rates[2].high);
   bool mssBearish = sweepBearish && (rates[1].close < rates[2].low);

   //--- Check current positions
   if(AlreadyInTrade()) return;

   //--- 5. Get ATR for SL Buffer
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handleLTF_ATR, 0, 0, 1, atr) < 1) return;
   double buffer = atr[0] * InpATRMultiplier;

   //--- 6. Entry Execution
   if(isBullishBias && mssBullish && isBullishFVG)
   {
      double entryPrice = rates[3].high;
      double sl = rates[2].low - buffer; // SL below sweep low
      double tp = entryPrice + InpTakeProfitPts * _Point;

      if(trade.BuyLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Elite Buy"))
         Print("LTF M15 Signal: Institutional Buy Limit at ", entryPrice);
   }
   else if(isBearishBias && mssBearish && isBearishFVG)
   {
      double entryPrice = rates[3].low;
      double sl = rates[2].high + buffer; // SL above sweep high
      double tp = entryPrice - InpTakeProfitPts * _Point;

      if(trade.SellLimit(InpLotSize, entryPrice, _Symbol, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ORDER_TIME_GTC, 0, "SMC Elite Sell"))
         Print("LTF M15 Signal: Institutional Sell Limit at ", entryPrice);
   }
}

//+------------------------------------------------------------------+
//| Manage Positions (Trailing Stop / BE)                            |
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

            // If Buy and price moved up at least 1:1 of original risk (or fixed distance)
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            {
               double originalRisk = openPrice - currentSL;
               if(currentPrice > openPrice + originalRisk && currentSL < openPrice)
               {
                  trade.PositionModify(ticket, openPrice + 10 * _Point, PositionGetDouble(POSITION_TP));
                  Print("Buy Position moved to Breakeven");
               }
            }
            else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            {
               double originalRisk = currentSL - openPrice;
               if(currentPrice < openPrice - originalRisk && (currentSL > openPrice || currentSL == 0))
               {
                  trade.PositionModify(ticket, openPrice - 10 * _Point, PositionGetDouble(POSITION_TP));
                  Print("Sell Position moved to Breakeven");
               }
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
