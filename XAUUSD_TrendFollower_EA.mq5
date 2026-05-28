//+------------------------------------------------------------------+
//|                                     XAUUSD_TrendFollower_EA.mq5 |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input int      InpEMAFast   = 20;       // Fast EMA Period
input int      InpEMAMed    = 50;       // Medium EMA Period
input int      InpEMASlow   = 190;      // Slow EMA Period (Trend)
input int      InpRSIPeriod = 14;       // RSI Period
input double   InpLotSize   = 0.1;      // Trade Lot Size
input int      InpStopLoss  = 500;      // Stop Loss in Points
input int      InpTakeProfit = 1000;     // Take Profit in Points
input int      InpMagicNum  = 123456;   // Magic Number

//--- Global variables
int      handleEMAFast;
int      handleEMAMed;
int      handleEMASlow;
int      handleRSI;
CTrade   trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize handles
   handleEMAFast = iMA(_Symbol, _Period, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMAMed  = iMA(_Symbol, _Period, InpEMAMed, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(_Symbol, _Period, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);

   if(handleEMAFast == INVALID_HANDLE || handleEMAMed == INVALID_HANDLE ||
      handleEMASlow == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNum);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleEMAFast);
   IndicatorRelease(handleEMAMed);
   IndicatorRelease(handleEMASlow);
   IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check for new bar to avoid multiple entries per bar
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, _Period, 0);
   if(current_time == last_time) return;
   last_time = current_time;

   //--- Arrays for indicator values
   double emaFast[], emaMed[], emaSlow[], rsiValue[], closePrice[];

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaMed, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsiValue, true);
   ArraySetAsSeries(closePrice, true);

   //--- Copy indicator data
   if(CopyBuffer(handleEMAFast, 0, 0, 3, emaFast) < 0 ||
      CopyBuffer(handleEMAMed, 0, 0, 3, emaMed) < 0 ||
      CopyBuffer(handleEMASlow, 0, 0, 3, emaSlow) < 0 ||
      CopyBuffer(handleRSI, 0, 0, 3, rsiValue) < 0 ||
      CopyClose(_Symbol, _Period, 0, 3, closePrice) < 0)
   {
      Print("Error copying indicator buffers");
      return;
   }

   //--- Check for valid values
   if(emaFast[1] == 0 || emaMed[1] == 0 || emaSlow[1] == 0 || rsiValue[1] == 0) return;

   //--- Trading Logic
   bool isBuy = (closePrice[1] > emaSlow[1]) && (emaFast[1] > emaMed[1]) && (rsiValue[1] > 50) && (rsiValue[1] < 70);
   bool isSell = (closePrice[1] < emaSlow[1]) && (emaFast[1] < emaMed[1]) && (rsiValue[1] < 50) && (rsiValue[1] > 30);

   //--- Check current positions for this magic number
   bool alreadyHavePosition = false;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            alreadyHavePosition = true;
            break;
         }
      }
   }

   if(!alreadyHavePosition)
   {
      if(isBuy)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = (InpStopLoss > 0) ? ask - InpStopLoss * _Point : 0;
         double tp = (InpTakeProfit > 0) ? ask + InpTakeProfit * _Point : 0;

         // Normalize prices
         sl = NormalizeDouble(sl, _Digits);
         tp = NormalizeDouble(tp, _Digits);

         if(!trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "XAUUSD Buy Trade"))
         {
            Print("Buy order failed. Error: ", trade.ResultRetcodeDescription());
         }
      }
      else if(isSell)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl = (InpStopLoss > 0) ? bid + InpStopLoss * _Point : 0;
         double tp = (InpTakeProfit > 0) ? bid - InpTakeProfit * _Point : 0;

         // Normalize prices
         sl = NormalizeDouble(sl, _Digits);
         tp = NormalizeDouble(tp, _Digits);

         if(!trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "XAUUSD Sell Trade"))
         {
            Print("Sell order failed. Error: ", trade.ResultRetcodeDescription());
         }
      }
   }
}
//+------------------------------------------------------------------+
