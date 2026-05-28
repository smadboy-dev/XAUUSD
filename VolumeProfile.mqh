//+------------------------------------------------------------------+
//|                                              VolumeProfile.mqh   |
//|                                  Copyright 2024, Trading Robot  |
//|                                             https://example.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules"
#property link      "https://example.com"
#property strict

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
