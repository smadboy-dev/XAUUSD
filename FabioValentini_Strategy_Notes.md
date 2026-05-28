# Fabio Valentini Auction Market Strategy - EA Requirements

## 1. Core Theory: Auction Market Theory (AMT)
- Market moves between **Balance** (rotational) and **Imbalance** (trending).
- **POC (Point of Control)**: Price level with the highest volume in a given range.
- **LVN (Low Volume Node)**: Price levels with significantly lower volume, representing areas price moves through quickly or rejects.

## 2. Setup 1: Trend Model (Out-of-Balance Continuation)
- **Session**: NY Session (NASDAQ/XAUUSD).
- **Market State**: Out of balance (strong displacement away from prior value).
- **Location**:
    1. Identify the impulsive leg that broke structure.
    2. Calculate Volume Profile for this leg.
    3. Find the most significant **LVN** within that leg.
- **Execution Trigger**: Retracement to the LVN + Aggression (Volume Climax / Price Rejection).
- **Target**: Next/Prior major balance POC.
- **Stop Loss**: Just beyond the LVN or the swing high/low of the entry candle.

## 3. Setup 2: Mean Reversion Model (Failed Breakout)
- **Session**: London Session / Compressed conditions.
- **Market State**: Price pushes out of a balance area (e.g., Previous Day's Range) but fails to hold and reclaims the range.
- **Location**:
    1. Identify the "reclaim leg" (the move that brought price back into balance).
    2. Calculate Volume Profile for the reclaim leg.
    3. Find the **LVN** of the reclaim leg.
- **Execution Trigger**: Retracement to the LVN + Aggression.
- **Target**: The POC of the original balance area.
- **Stop Loss**: Just beyond the failed breakout high/low.

## 4. Technical Implementation in MT5
- **Volume Profile**: Since MT5 doesn't have a native "Volume Profile on Range" function for EAs, I will implement a custom class `CVolumeProfile` that:
    - Takes a start and end time/index.
    - Bins price into levels (e.g., every 10-50 points).
    - Accumulates Tick Volume.
    - Finds POC (Max Volume) and LVN (Local Minima).
- **Aggression**: Measured via Volume spikes (current volume > X * average volume) or Pin Bar / Engulfing patterns at the LVN.
- **Risk Management**: Fixed percentage risk per trade (0.25% - 0.5%).

## 5. EA Parameters
- `InpRiskPercent`: 0.5%
- `InpLondonStart`: 10:00 MSK
- `InpNYStart`: 15:30 MSK
- `InpProfileStep`: 50 points (step size for volume bins)
- `InpVolumeClimaxMult`: 2.0x (to detect aggression)
