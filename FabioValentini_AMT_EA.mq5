//+------------------------------------------------------------------+
//|                                     FabioValentini_AMT_EA.mq5    |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Simple Volume Profile Class for MQL5                             |
//+------------------------------------------------------------------+
class CVolumeProfile
{
private:
   string         m_symbol;
   ENUM_TIMEFRAMES m_period;
   double         m_step; // Bin size in points

   struct PriceBin {
      double price;
      long   volume;
   };

   PriceBin       m_bins[];

public:
   CVolumeProfile(string symbol, ENUM_TIMEFRAMES period, int step_points)
   {
      m_symbol = symbol;
      m_period = period;
      m_step = step_points * SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   }

   // Calculate profile for a specific bar range [start_index, end_index] inclusive
   bool Calculate(int start_index, int end_index)
   {
      ArrayFree(m_bins);
      if(start_index < end_index) return false;

      int count = start_index - end_index + 1;
      MqlRates rates[];
      if(CopyRates(m_symbol, m_period, end_index, count, rates) < count) return false;

      double min_price = rates[0].low;
      double max_price = rates[0].high;

      for(int i=1; i<count; i++)
      {
         if(rates[i].low < min_price) min_price = rates[i].low;
         if(rates[i].high > max_price) max_price = rates[i].high;
      }

      int num_bins = (int)((max_price - min_price) / m_step) + 1;
      if(ArrayResize(m_bins, num_bins) < 0) return false;

      for(int i=0; i<num_bins; i++)
      {
         m_bins[i].price = min_price + (i * m_step);
         m_bins[i].volume = 0;
      }

      for(int i=0; i<count; i++)
      {
         int start_bin = (int)((rates[i].low - min_price) / m_step);
         int end_bin = (int)((rates[i].high - min_price) / m_step);

         if(start_bin < 0) start_bin = 0;
         if(end_bin >= num_bins) end_bin = num_bins - 1;

         int num_covered_bins = end_bin - start_bin + 1;
         if(num_covered_bins > 0)
         {
            long vol_per_bin = rates[i].tick_volume / num_covered_bins;
            for(int j = start_bin; j <= end_bin; j++)
            {
               m_bins[j].volume += vol_per_bin;
            }
         }
      }
      return true;
   }

   double GetPOC()
   {
      long max_vol = -1;
      double poc = 0;
      for(int i=0; i<ArraySize(m_bins); i++)
      {
         if(m_bins[i].volume > max_vol)
         {
            max_vol = m_bins[i].volume;
            poc = m_bins[i].price;
         }
      }
      return poc;
   }

   // Returns the price of the most significant LVN between two price levels
   double GetLVN(double price_low, double price_high)
   {
      long min_vol = 9223372036854775807;
      double lvn = 0;
      bool found = false;

      for(int i=0; i<ArraySize(m_bins); i++)
      {
         if(m_bins[i].price >= price_low && m_bins[i].price <= price_high)
         {
            if(m_bins[i].volume < min_vol)
            {
               min_vol = m_bins[i].volume;
               lvn = m_bins[i].price;
               found = true;
            }
         }
      }
      return found ? lvn : 0;
   }

   int GetBinsCount() { return ArraySize(m_bins); }
};

//--- Input parameters
input double   InpRiskPercent    = 0.5;      // Risk Percent per Trade
input int      InpLondonStart    = 10;       // London Session Start (Hour)
input int      InpNYStart        = 15;       // NY Session Start (Hour)
input int      InpNYEnd          = 22;       // Trading End Hour
input int      InpProfileStep    = 50;       // Volume Profile Bin Step (Points)
input double   InpVolClimaxMult  = 2.0;      // Volume Aggression Multiplier
input int      InpMagicNum       = 888777;   // Magic Number
input int      InpStopBuffer     = 50;       // Stop Loss Buffer (Points)

//--- Global variables
CTrade         trade;
CVolumeProfile *profile;
double         prevDayPOC = 0;
double         prevDayHigh = 0;
double         prevDayLow = 0;
datetime       lastDayUpdate = 0;

// Market State Variables
datetime       impulseStartTime = 0;
datetime       reclaimStartTime = 0;
double         setupSL = 0;
double         setupTP = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   profile = new CVolumeProfile(_Symbol, _Period, InpProfileStep);
   UpdatePreviousDayLevels();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(CheckPointer(profile) == POINTER_DYNAMIC)
      delete profile;
}

//+------------------------------------------------------------------+
//| Update Previous Day Levels                                       |
//+------------------------------------------------------------------+
void UpdatePreviousDayLevels()
{
   MqlRates rates[];
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, rates) == 1)
   {
      prevDayHigh = rates[0].high;
      prevDayLow = rates[0].low;
      CVolumeProfile dailyProfile(_Symbol, PERIOD_H1, InpProfileStep);
      datetime startOfDay = rates[0].time;
      datetime endOfDay = startOfDay + PeriodSeconds(PERIOD_D1) - 1;
      int startIdx = iBarShift(_Symbol, PERIOD_H1, startOfDay);
      int endIdx = iBarShift(_Symbol, PERIOD_H1, endOfDay);
      if(dailyProfile.Calculate(startIdx, endIdx))
         prevDayPOC = dailyProfile.GetPOC();
      lastDayUpdate = iTime(_Symbol, PERIOD_D1, 0);
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. New Day Check
   if(iTime(_Symbol, PERIOD_D1, 0) > lastDayUpdate)
   {
      UpdatePreviousDayLevels();
      impulseStartTime = 0;
      reclaimStartTime = 0;
   }

   // 2. Session Check
   MqlDateTime dt;
   TimeCurrent(dt);
   bool isLondon = (dt.hour >= InpLondonStart && dt.hour < InpNYStart);
   bool isNY = (dt.hour >= InpNYStart && dt.hour < InpNYEnd);

   if(!isLondon && !isNY) return;

   // 3. Process Logic
   if(AlreadyInTrade()) return;

   if(isLondon) RunLondonMeanReversion();
   if(isNY) RunNYTrendContinuation();
}

//+------------------------------------------------------------------+
//| London Mean Reversion Logic                                      |
//+------------------------------------------------------------------+
void RunLondonMeanReversion()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   static bool brokeHigh = false;
   static bool brokeLow = false;

   // Watch for price to push out of prev day range
   if(currentPrice > prevDayHigh) brokeHigh = true;
   if(currentPrice < prevDayLow) brokeLow = true;

   // Watch for reclaim
   if(brokeHigh && currentPrice < prevDayHigh - 100 * _Point)
   {
      // Reclaimed inside balance from above
      if(reclaimStartTime == 0) reclaimStartTime = TimeCurrent();

      // Calculate LVN for the reclaim move
      int currentIdx = 0;
      int startIdx = iBarShift(_Symbol, _Period, reclaimStartTime);
      if(profile.Calculate(startIdx, currentIdx))
      {
         double lvn = profile.GetLVN(prevDayHigh - 500 * _Point, prevDayHigh + 100 * _Point);
         if(lvn > 0) ExecuteAtLVN(lvn, prevDayHigh + InpStopBuffer * _Point, prevDayPOC, "MR Short");
      }
   }
   else if(brokeLow && currentPrice > prevDayLow + 100 * _Point)
   {
      // Reclaimed inside balance from below
      if(reclaimStartTime == 0) reclaimStartTime = TimeCurrent();

      int currentIdx = 0;
      int startIdx = iBarShift(_Symbol, _Period, reclaimStartTime);
      if(profile.Calculate(startIdx, currentIdx))
      {
         double lvn = profile.GetLVN(prevDayLow - 100 * _Point, prevDayLow + 500 * _Point);
         if(lvn > 0) ExecuteAtLVN(lvn, prevDayLow - InpStopBuffer * _Point, prevDayPOC, "MR Long");
      }
   }
   else if(currentPrice < prevDayHigh && currentPrice > prevDayLow)
   {
      // Inside range, reset breakout flags if no reclaim was tracked
      if(reclaimStartTime == 0)
      {
         brokeHigh = false;
         brokeLow = false;
      }
   }
}

//+------------------------------------------------------------------+
//| NY Trend Continuation Logic                                      |
//+------------------------------------------------------------------+
void RunNYTrendContinuation()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   static bool trendTriggered = false;

   // Detect "Out of Balance" - price breaking prev day high/low with momentum
   if(currentPrice > prevDayHigh + 500 * _Point || currentPrice < prevDayLow - 500 * _Point)
      trendTriggered = true;

   if(trendTriggered)
   {
      if(impulseStartTime == 0) impulseStartTime = TimeCurrent();

      int currentIdx = 0;
      int startIdx = iBarShift(_Symbol, _Period, impulseStartTime);

      if(profile.Calculate(startIdx, currentIdx))
      {
         if(currentPrice > prevDayHigh)
         {
            double lvn = profile.GetLVN(prevDayHigh, currentPrice);
            if(lvn > 0)
            {
               double tp = lvn + (lvn - (lvn - 200 * _Point)) * 3.0; // 3R target for trend
               ExecuteAtLVN(lvn, lvn - 200 * _Point, tp, "Trend Long");
            }
         }
         else
         {
            double lvn = profile.GetLVN(currentPrice, prevDayLow);
            if(lvn > 0)
            {
               double tp = lvn - ((lvn + 200 * _Point) - lvn) * 3.0; // 3R target for trend
               ExecuteAtLVN(lvn, lvn + 200 * _Point, tp, "Trend Short");
            }
         }
      }
   }
   else
   {
      impulseStartTime = 0; // Reset if price returns to range
      trendTriggered = false;
   }
}

//+------------------------------------------------------------------+
//| Execution with Volume Aggression Check                           |
//+------------------------------------------------------------------+
void ExecuteAtLVN(double entryPrice, double sl, double tp, string comment)
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance = MathAbs(currentPrice - entryPrice);

   // Only check aggression if we are close to the LVN
   if(distance < 100 * _Point)
   {
      // Use the last completed bar for a stable volume comparison
      long lastCompletedVol = iTickVolume(_Symbol, _Period, 1);
      double avgVol = 0;
      for(int i=2; i<=11; i++) avgVol += (double)iTickVolume(_Symbol, _Period, i);
      avgVol /= 10;

      if((double)lastCompletedVol > avgVol * InpVolClimaxMult)
      {
         double lot = CalculateLotSize(MathAbs(entryPrice - sl));
         if(entryPrice > sl) // Long
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            trade.Buy(lot, _Symbol, ask, sl, tp, comment);
         }
         else // Short
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            trade.Sell(lot, _Symbol, bid, sl, tp, comment);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Lot Size Calculation based on Risk                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance)
{
   if(sl_distance <= 0) return 0.01;
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot = riskAmount / (sl_distance / tickSize * tickValue);
   return NormalizeDouble(lot, 2);
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
      if(OrderSelect(OrderGetTicket(i)))
         if(OrderGetInteger(ORDER_MAGIC) == InpMagicNum) return true;

   return false;
}
