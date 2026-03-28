//+------------------------------------------------------------------+
//|                                              TrendProphet_EA.mq5 |
//|                                  Copyright 2024, Trading Project |
//+------------------------------------------------------------------+
#property strict

//--- Input Parameters
input int      InpEMAPeriod     = 50;          // EMA Trend Period
input int      InpATRPeriod     = 14;          // ATR Volatility Period
input double   InpRiskPercent   = 1.0;         // Risk per trade (% of Equity)
input double   InpStopMult      = 1.5;         // ATR Multiplier for Stop Loss
input double   InpTargetProfitUSD = 100.0;     // Fixed Profit Target ($) per trade
input double   InpDailyCapUSD   = 200.0;       // Stop trading for the day at this profit ($)

//--- Global Variables
int            handleEMA;
int            handleATR;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   handleEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   
   if(handleEMA == INVALID_HANDLE || handleATR == INVALID_HANDLE) 
      return(INIT_FAILED);
      
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Safety Checks: Existing positions or Daily Goal reached
   if(PositionsTotal() > 0) return;
   if(IsDailyCapReached()) return;

   // 2. Get Indicator Data
   double ema[], atr[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(handleEMA, 0, 0, 2, ema) < 2 || CopyBuffer(handleATR, 0, 0, 2, atr) < 2) 
      return;
   
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // 3. Logic: Buy if Price > EMA (Trend Following)
   // Using ema[1] (previous closed candle) for signal stability
   if(currentAsk > ema[1])
   {
      double stopLossDistance = atr[0] * InpStopMult;
      double slPrice = currentBid - stopLossDistance; // SL for Buy is below Bid
      
      double lotSize = CalculateLotSize(stopLossDistance);
      
      // Calculate TP based on the requested $100 profit
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      
      // Points needed = Target Cash / (Lots * Value of 1 point)
      double tpPoints = InpTargetProfitUSD / (lotSize * (tickValue / tickSize));
      double tpPrice  = currentAsk + tpPoints;
      
      ExecuteTrade(ORDER_TYPE_BUY, lotSize, slPrice, tpPrice);
   }
}

//+------------------------------------------------------------------+
//| Check if Daily Profit Target has been met                        |
//+------------------------------------------------------------------+
bool IsDailyCapReached()
{
   double dailyProfit = 0;
   // Get the start of the current day (00:00)
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0); 
   
   // Load history from start of day to now
   HistorySelect(dayStart, TimeCurrent());
   
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      // Only count deals that closed a position (DEAL_ENTRY_OUT)
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         dailyProfit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      }
   }
   
   if(dailyProfit >= InpDailyCapUSD)
   {
      static bool printed = false;
      if(!printed) { Print("Daily profit cap reached: $", dailyProfit); printed = true; }
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on % Risk                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   double riskAmount = accountEquity * (InpRiskPercent / 100.0);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // 1. Calculate lots based on Risk
   double points = slDistance / tickSize;
   if(points <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   double lots = riskAmount / (points * tickValue);
   
   // 2. SAFETY CHECK: Margin Limit
   // We check how much margin is required for 1 lot
   double marginReqPerLot;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReqPerLot))
   {
      // Don't use more than 50% of free margin for a single trade
      double maxLotsByMargin = (freeMargin * 0.5) / marginReqPerLot;
      lots = MathMin(lots, maxLotsByMargin);
   }

   // 3. SAFETY CHECK: Hard Cap
   // Even on a $100k account, 18 lots of Gold is extreme. 
   // Let's cap it at a reasonable number (e.g., 5.0 lots) or broker Max.
   double maxBrokerLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMin(lots, 5.0); // Hard cap at 5 lots for safety
   
   // 4. Standard MT5 constraints
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   lots = MathFloor(lots / lotStep) * lotStep;
   
   return MathMax(minLot, MathMin(maxBrokerLot, lots));
}

//+------------------------------------------------------------------+
//| Execute Trade Order                                              |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double vol, double sl, double tp)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   
   uint fillingMode = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = vol;
   request.type   = type;
   request.price  = NormalizeDouble(SymbolInfoDouble(_Symbol, (type == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID), _Digits);
   request.sl     = NormalizeDouble(sl, _Digits);
   request.tp     = NormalizeDouble(tp, _Digits);
   request.magic  = 123456;
   request.deviation = 10;

   // Filling mode selection
   if((fillingMode & SYMBOL_FILLING_FOK) != 0)      request.type_filling = ORDER_FILLING_FOK;
   else if((fillingMode & SYMBOL_FILLING_IOC) != 0) request.type_filling = ORDER_FILLING_IOC;
   else                                             request.type_filling = ORDER_FILLING_RETURN;
   
   if(!OrderSend(request, result))
      Print("Trade failed! Error: ", GetLastError(), " Result Code: ", result.retcode);
   else
      Print("Trade executed! Lot: ", vol, " SL: ", request.sl, " TP: ", request.tp);
}
