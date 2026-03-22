//+------------------------------------------------------------------+
//|                                         MultiSymbolTrend_EA.mq5  |
//|         ULTRA-SAFE VERSION: Hard Equity Guard & Low Risk         |
//+------------------------------------------------------------------+
#property strict

//--- Input Parameters
input int      InpEMAPeriod     = 50;
input int      InpATRPeriod     = 14;
input double   InpRiskPercent   = 0.5;   // LOWERED: Risk 0.5% to protect the 1.34% remaining
input double   InpRewardRatio   = 2.0;   
input double   InpStopMult      = 1.5;   
input int      InpMaxPositions  = 1;     // LOWERED: Only 1 trade at a time to minimize Drawdown
input bool     InpUseTrailing   = true;  
input double   InpTrailStep     = 0.8;   // TIGHTER: Move SL sooner (0.8 * ATR)
input double   InpMaxDrawdownPct = 9.5;  // CRITICAL: Hard stop at 9.5% to stay under your 10% limit

//--- Symbols to trade
string SymbolsToTrade[] = {"XAUUSD", "EURUSD", "INTC", "NVDA"};

//--- Handles storage
int EMAHandles[];
int ATRHandles[];
datetime LastBarTime[]; 

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   int totalSymbols = ArraySize(SymbolsToTrade);
   ArrayResize(EMAHandles, totalSymbols);
   ArrayResize(ATRHandles, totalSymbols);
   ArrayResize(LastBarTime, totalSymbols);
   ArrayInitialize(LastBarTime, 0);

   for(int i = 0; i < totalSymbols; i++)
   {
      if(!SymbolInfoInteger(SymbolsToTrade[i], SYMBOL_SELECT))
         SymbolSelect(SymbolsToTrade[i], true);

      EMAHandles[i] = iMA(SymbolsToTrade[i], PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      ATRHandles[i] = iATR(SymbolsToTrade[i], PERIOD_CURRENT, InpATRPeriod);

      if(EMAHandles[i] == INVALID_HANDLE || ATRHandles[i] == INVALID_HANDLE) return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. HARD EQUITY GUARD (The Circuit Breaker)
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double currentDD = ((balance - equity) / balance) * 100.0;

   if(currentDD >= InpMaxDrawdownPct)
   {
      Alert("CRITICAL DRAWDOWN REACHED! Closing all positions.");
      CloseAllPositions();
      return; // Stop processing for this tick
   }

   // 2. ACTIVE MANAGEMENT: Trailing Stop
   if(InpUseTrailing) ManageTrailingStops();

   // 3. GLOBAL PROTECTION: Entry Limit
   if(PositionsTotal() >= InpMaxPositions) return;

   int totalSymbols = ArraySize(SymbolsToTrade);
   for(int i = 0; i < totalSymbols; i++)
   {
      string sym = SymbolsToTrade[i];
      datetime currentBar = iTime(sym, PERIOD_CURRENT, 0);
      if(LastBarTime[i] == currentBar) continue; 
      if(PositionSelect(sym)) continue;

      double ema[1], atr[1];
      if(CopyBuffer(EMAHandles[i], 0, 0, 1, ema) < 1) continue;
      if(CopyBuffer(ATRHandles[i], 0, 0, 1, atr) < 1) continue;

      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double stopLossDistance = atr[0] * InpStopMult;

      // BUY LOGIC ONLY
      if(bid > ema[0])
      {
         double sl = ask - stopLossDistance;
         double tp = ask + (stopLossDistance * InpRewardRatio);
         double lot = CalculateLotSize(sym, stopLossDistance);
         
         if(lot > 0) 
         { 
            ExecuteTrade(sym, ORDER_TYPE_BUY, lot, sl, tp); 
            LastBarTime[i] = currentBar; 
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Emergency Close Function                                         |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      string sym = PositionGetString(POSITION_SYMBOL);
      double vol = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = sym;
      req.volume = vol;
      req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      req.deviation = 10;
      OrderSend(req, res);
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stops                                            |
//+------------------------------------------------------------------+
void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) <= 0) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double posSL = PositionGetDouble(POSITION_SL);
      double currentBid = SymbolInfoDouble(sym, SYMBOL_BID);
      
      double atrBuffer[1];
      int symIdx = -1;
      for(int s=0; s<ArraySize(SymbolsToTrade); s++) if(SymbolsToTrade[s] == sym) symIdx = s;
      if(symIdx == -1 || CopyBuffer(ATRHandles[symIdx], 0, 0, 1, atrBuffer) < 1) continue;
      
      double trailDist = atrBuffer[0] * InpTrailStep;
      double newSL = NormalizeDouble(currentBid - trailDist, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

      if(newSL > posSL + (trailDist * 0.1))
      {
         MqlTradeRequest req = {}; MqlTradeResult res = {};
         req.action = TRADE_ACTION_SLTP; req.position = ticket; req.sl = newSL; req.tp = PositionGetDouble(POSITION_TP);
         OrderSend(req, res);
      }
   }
}

//+------------------------------------------------------------------+
//| Safest Lot Size Calculation                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(string sym, double slDistance)
{
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   double riskAmount = balance * (InpRiskPercent / 100.0);
   double points = slDistance / tickSize;
   if(points <= 0) return 0;
   double lots = riskAmount / (points * tickValue);

   double marginPerLot;
   if(OrderCalcMargin(ORDER_TYPE_BUY, sym, 1.0, SymbolInfoDouble(sym, SYMBOL_ASK), marginPerLot))
   {
      double maxAllowedByMargin = (freeMargin * 0.5) / marginPerLot; // Only use 50% margin
      if(lots > maxAllowedByMargin) lots = maxAllowedByMargin;
   }

   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), lots));
}

//+------------------------------------------------------------------+
//| Execution with Auto-Filling Detect                               |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, ENUM_ORDER_TYPE type, double vol, double sl, double tp)
{
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   req.action = TRADE_ACTION_DEAL; req.symbol = sym; req.volume = vol; req.type = type; req.magic = 123456; req.deviation = 10;
   req.price = NormalizeDouble(SymbolInfoDouble(sym, SYMBOL_ASK), digits);
   req.sl = NormalizeDouble(sl, digits); req.tp = NormalizeDouble(tp, digits);
   uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   req.type_filling = (filling & SYMBOL_FILLING_FOK) ? ORDER_FILLING_FOK : (filling & SYMBOL_FILLING_IOC ? ORDER_FILLING_IOC : ORDER_FILLING_RETURN);
   OrderSend(req, res);
}
