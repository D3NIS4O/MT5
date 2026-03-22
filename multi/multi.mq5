//+------------------------------------------------------------------+
//|                                      MultiSymbolTrend_EA.mq5    |
//+------------------------------------------------------------------+
#property strict

//--- Input Parameters
input int      InpEMAPeriod   = 50;
input int      InpATRPeriod   = 14;
input double   InpRiskPercent = 1.0;
input double   InpRewardRatio = 2.0;
input double   InpStopMult    = 1.5;

//--- Symbols to trade
string SymbolsToTrade[] = {"XAUUSD", "EURUSD", "INTC", "NVDA"};

//--- Handles storage
int EMAHandles[];
int ATRHandles[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int totalSymbols = ArraySize(SymbolsToTrade);
   ArrayResize(EMAHandles, totalSymbols);
   ArrayResize(ATRHandles, totalSymbols);

   for(int i = 0; i < totalSymbols; i++)
   {
      EMAHandles[i] = iMA(SymbolsToTrade[i], PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      ATRHandles[i] = iATR(SymbolsToTrade[i], PERIOD_CURRENT, InpATRPeriod);

      if(EMAHandles[i] == INVALID_HANDLE || ATRHandles[i] == INVALID_HANDLE)
      {
         Print("Failed to create indicators for ", SymbolsToTrade[i]);
         return(INIT_FAILED);
      }
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int totalSymbols = ArraySize(SymbolsToTrade);
   for(int i = 0; i < totalSymbols; i++)
   {
      string sym = SymbolsToTrade[i];

      // Skip if we already have a position for this symbol
      if(PositionSelect(sym)) continue;

      // Copy indicator data
      double ema[2], atr[2];
      ArraySetAsSeries(ema, true);
      ArraySetAsSeries(atr, true);

      if(CopyBuffer(EMAHandles[i], 0, 0, 2, ema) < 2) continue;
      if(CopyBuffer(ATRHandles[i], 0, 0, 2, atr) < 2) continue;

      double price = SymbolInfoDouble(sym, SYMBOL_ASK);

      // Simple trend logic: Buy if price above EMA
      if(price > ema[0])
      {
         double stopLossDistance = atr[0] * InpStopMult;
         double sl = price - stopLossDistance;
         double tp = price + stopLossDistance * InpRewardRatio;

         double lot = CalculateLotSize(sym, stopLossDistance);
         ExecuteTrade(sym, ORDER_TYPE_BUY, lot, sl, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Lot size calculation per symbol                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double slDistance)
{
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   double riskAmount = accountEquity * (InpRiskPercent / 100.0);
   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double points = slDistance / tickSize;
   double lots = riskAmount / (points * tickValue);

   // Margin check
   double marginRequired;
   if(OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, SymbolInfoDouble(sym, SYMBOL_ASK), marginRequired))
   {
      double maxLotsAllowed = freeMargin / marginRequired;
      if(lots > maxLotsAllowed * 0.9) lots = maxLotsAllowed * 0.9;
   }

   // Respect min/max lot
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| Trade execution per symbol                                        |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, ENUM_ORDER_TYPE type, double vol, double sl, double tp)
{
   MqlTradeRequest req = {};
   MqlTradeResult  res = {};

   uint fillingMode = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = vol;
   req.type   = type;
   req.price  = SymbolInfoDouble(sym, (type == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID);
   req.sl     = sl;
   req.tp     = tp;
   req.magic  = 123456;
   req.deviation = 10;

   if((fillingMode & SYMBOL_FILLING_FOK) != 0)       req.type_filling = ORDER_FILLING_FOK;
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0)  req.type_filling = ORDER_FILLING_IOC;
   else                                              req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
      Print("Trade failed for ", sym, " Error: ", GetLastError(), " Code: ", res.retcode);
   else
      Print("Trade executed for ", sym, " Volume: ", vol);
}
