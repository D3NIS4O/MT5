//+------------------------------------------------------------------+
//|                                              TrendProphet_EA.mq5 |
//|                                  Copyright 2024, Trading Project |
//+------------------------------------------------------------------+
#property strict

//--- Input Parameters
input int      InpEMAPeriod   = 50;          // EMA Trend Period
input int      InpATRPeriod   = 14;          // ATR Volatility Period
input double   InpRiskPercent = 1.0;         // Risk per trade (%)
input double   InpRewardRatio = 2.0;         // Reward-to-Risk Ratio
input double   InpStopMult    = 1.5;         // ATR Multiplier for Stop Loss

//--- Global Variables
int            handleEMA;
int            handleATR;
double         capital = 100000.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   handleEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   
   if(handleEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE) return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Check if we already have a position open
   if(PositionsTotal() > 0) return;

   // 2. Get Indicator Data
   double ema[], atr[], price[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(handleEMA, 0, 0, 2, ema) < 2 || CopyBuffer(handleATR, 0, 0, 2, atr) < 2) return;
   
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // 3. Logic: Buy if Price > EMA (Simplified Trend)
   if(currentPrice > ema[0])
   {
      double stopLossDistance = atr[0] * InpStopMult;
      double slPrice = currentPrice - stopLossDistance;
      double tpPrice = currentPrice + (stopLossDistance * InpRewardRatio);
      
      double lotSize = CalculateLotSize(stopLossDistance);
      ExecuteTrade(ORDER_TYPE_BUY, lotSize, slPrice, tpPrice);
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on 1% Risk                              |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   
   double riskAmount = accountEquity * (InpRiskPercent / 100.0);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Calculate mathematical lots based on risk
   double points = slDistance / tickSize;
   double lots = riskAmount / (points * tickValue);
   
   // --- SAFETY CHECK: Margin ---
   double marginRequired;
   // Check how much margin 1 lot requires
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      double maxLotsAllowed = freeMargin / marginRequired;
      // Reduce lots if they exceed 90% of available margin
      if(lots > (maxLotsAllowed * 0.9)) 
         lots = maxLotsAllowed * 0.9;
   }

   // Standard MT5 lot constraints
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| Execute Trade Order                                              |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double vol, double sl, double tp)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   
   // --- Get the allowed filling mode for this symbol ---
   uint fillingMode = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = vol;
   request.type   = type;
   request.price  = SymbolInfoDouble(_Symbol, (type == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID);
   request.sl     = sl;
   request.tp     = tp;
   request.magic  = 123456;
   request.deviation = 10;

   // Logic to pick the right filling mode
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)     request.type_filling = ORDER_FILLING_FOK;
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) request.type_filling = ORDER_FILLING_IOC;
   else                                            request.type_filling = ORDER_FILLING_RETURN;
   
   if(!OrderSend(request, result))
      Print("Trade failed! Error: ", GetLastError(), " Result Code: ", result.retcode);
   else
      Print("Trade executed successfully!");
}
