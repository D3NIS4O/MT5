//+------------------------------------------------------------------+
//|                                         HighFreq_1to1_Scalper.mq5|
//|                                  Copyright 2026, AI Collaborator |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Gemini AI"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>

//--- User Inputs
input int      RSIPeriod      = 7;       // Shorter period = more signals
input int      RSI_Low        = 35;      // Buy Level
input int      RSI_High       = 65;      // Sell Level
input double   MaxDrawdownPct = 9.0;     
input int      StopLossPips   = 30;      // Tight SL for scalping
input int      TakeProfitPips = 50;      // Smaller TP for more frequent closures

CTrade         trade;
int            rsiHandle;

int OnInit() {
   rsiHandle = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
   trade.SetExpertMagicNumber(999888);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   // 1. Drawdown Safety (The 10% Rule)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(((balance - equity) / balance) * 100.0 >= MaxDrawdownPct) {
      CloseAllPositions();
      ExpertRemove();
      return;
   }

   // 2. High Frequency logic: Allow up to 2 positions if they are in opposite directions 
   // or just 1 for strict 1:1. Let's stick to 1 to stay safe on 1:1 margin.
   if(PositionsTotal() < 1) {
      double rsiBuffer[];
      ArraySetAsSeries(rsiBuffer, true);
      if(CopyBuffer(rsiHandle, 0, 0, 2, rsiBuffer) < 2) return;

      // 3. Calculation for 1:1 Leverage
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      // Using 98% of balance to allow for spread while staying near 1:1
      double availableLots = (balance * 0.98) / (price * contractSize);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double finalLot = MathFloor(availableLots / step) * step;

      // 4. Entry: RSI Mean Reversion
      if(rsiBuffer[0] < RSI_Low) { // Oversold
         double sl = price - (StopLossPips * _Point * 10);
         double tp = price + (TakeProfitPips * _Point * 10);
         trade.Buy(finalLot, _Symbol, price, sl, tp, "Scalp_Buy");
      }
      else if(rsiBuffer[0] > RSI_High) { // Overbought
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double sl = bid + (StopLossPips * _Point * 10);
         double tp = bid - (TakeProfitPips * _Point * 10);
         trade.Sell(finalLot, _Symbol, bid, sl, tp, "Scalp_Sell");
      }
   }
}

void CloseAllPositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      trade.PositionClose(PositionGetTicket(i));
}