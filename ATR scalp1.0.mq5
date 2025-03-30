//+------------------------------------------------------------------+
//|                                   OptimizedBreakoutTradingBot.mq5 |
//|                        Copyright 2025                            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property version   "1.00"
#property strict

// Include the Trade library
#include <Trade\Trade.mqh>

// Define input parameters
input double LotSize = 0.2;            // Trading lot size
input int StopDistance = 25;           // Distance for stop orders in points (reduced for 1min timeframe)
input int InitialStopLoss = 35;        // Initial stop loss in points (tightened)
input int TakeProfit = 70;             // Take profit in points (reduced for faster profit taking)
input int ProfitTrigger = 15;          // Points of profit before moving SL (reduced)
input int ProfitLock = 10;             // Points of profit to lock in (reduced)
input int TrailStart = 20;             // Points of profit before trailing begins (reduced)
input int TrailDistance = 10;          // Trailing stop distance in points (tightened)
input int RangeLength = 10;            // Number of bars to calculate range (new parameter)
input bool UseATR = true;              // Option to use ATR for dynamic stops (new parameter)
input int ATRPeriod = 14;              // ATR period (new parameter)
input double ATRMultiplierSL = 1.5;    // ATR multiplier for stop loss (new parameter)
input double ATRMultiplierTP = 3.0;    // ATR multiplier for take profit (new parameter)
input bool CloseOnOppositeSignal = true; // Close position on opposite breakout signal (new parameter)
input int MaxSpread = 200;              // Maximum allowed spread in points (new parameter)

// Global variables to store order tickets
ulong buyStopTicket = 0;
ulong sellStopTicket = 0;
bool ordersPlaced = false;             // Flag to track active order pair
datetime lastBarTime = 0;              // To track new bars
double previousRange = 0;              // Store the previous price range

// Declare trading object
CTrade trade;

// Handle for ATR indicator
int atrHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize trade object
   trade.SetExpertMagicNumber(123456);
   trade.SetDeviationInPoints(5);      // Reduced for tighter execution
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize ATR indicator
   if(UseATR)
   {
      atrHandle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Error creating ATR indicator: ", GetLastError());
         return(INIT_FAILED);
      }
   }
   
   // Close any existing orders at start
   CloseExistingOrders();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release ATR indicator handle
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   
   // Get current spread
   double currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   // Only proceed if spread is acceptable
   if(currentSpread > MaxSpread)
   {
      Comment("Current spread (", currentSpread, ") exceeds maximum allowed (", MaxSpread, ")");
      return;
   }
   else
   {
      Comment(""); // Clear comment
   }
   
   // If a new bar has formed, recalculate breakout levels
   if(isNewBar)
   {
      lastBarTime = currentBarTime;
      CalculateBreakoutLevels();
   }
   
   if(ordersPlaced == false)
   {
      PlaceStopOrders();
   }
   else
   {
      ManageOrders();
      CheckAndResetOrders();
   }
}

//+------------------------------------------------------------------+
//| Close all existing orders                                        |
//+------------------------------------------------------------------+
void CloseExistingOrders()
{
   // Close all active positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            // Check if this position belongs to current symbol
            if(PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               trade.PositionClose(ticket);
            }
         }
      }
   }
   
   // Delete all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderSelect(ticket))
         {
            // Check if this order belongs to current symbol
            if(OrderGetString(ORDER_SYMBOL) == _Symbol)
            {
               trade.OrderDelete(ticket);
            }
         }
      }
   }
   
   // Reset flags
   ordersPlaced = false;
   buyStopTicket = 0;
   sellStopTicket = 0;
}

//+------------------------------------------------------------------+
//| Calculate breakout levels based on recent price action          |
//+------------------------------------------------------------------+
void CalculateBreakoutLevels()
{
   double highestHigh = 0;
   double lowestLow = 9999999;
   
   // Find the highest high and lowest low over the last RangeLength bars
   for(int i = 1; i <= RangeLength; i++)
   {
      double high = iHigh(_Symbol, PERIOD_M1, i);
      double low = iLow(_Symbol, PERIOD_M1, i);
      
      if(high > highestHigh) highestHigh = high;
      if(low < lowestLow) lowestLow = low;
   }
   
   // Calculate the current range
   previousRange = highestHigh - lowestLow;
}

//+------------------------------------------------------------------+
//| Place new Buy Stop & Sell Stop orders                           |
//+------------------------------------------------------------------+
void PlaceStopOrders()
{
   if(ordersPlaced == true)
      return;  // Exit function if an order pair already exists
   
   // Get current bid and ask prices
   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Dynamic stop distances based on ATR if enabled
   double stopDistance = StopDistance;
   double initialStopLoss = InitialStopLoss;
   double takeProfit = TakeProfit;
   
   if(UseATR && atrHandle != INVALID_HANDLE)
   {
      double atrValue[];
      if(CopyBuffer(atrHandle, 0, 0, 1, atrValue) > 0)
      {
         double atrPoints = atrValue[0] / _Point;
         stopDistance = (int)MathRound(atrPoints * 0.5);        // Use 50% of ATR for breakout level
         initialStopLoss = (int)MathRound(atrPoints * ATRMultiplierSL);  // ATR-based stop loss
         takeProfit = (int)MathRound(atrPoints * ATRMultiplierTP);      // ATR-based take profit
         
         Print("ATR: ", atrValue[0], " points: ", atrPoints, 
               " stopDistance: ", stopDistance, 
               " initialStopLoss: ", initialStopLoss,
               " takeProfit: ", takeProfit);
      }
   }
   
   // Calculate entry prices and take profit levels
   double buyStopPrice = NormalizeDouble(askPrice + (stopDistance * _Point), _Digits);
   double sellStopPrice = NormalizeDouble(bidPrice - (stopDistance * _Point), _Digits);
   
   // Calculate initial stop loss levels
   double buySL = NormalizeDouble(buyStopPrice - (initialStopLoss * _Point), _Digits);
   double sellSL = NormalizeDouble(sellStopPrice + (initialStopLoss * _Point), _Digits);
   
   double buyTP = NormalizeDouble(buyStopPrice + (takeProfit * _Point), _Digits);
   double sellTP = NormalizeDouble(sellStopPrice - (takeProfit * _Point), _Digits);
   
   // Place Buy Stop order with initial stop loss
   if(trade.BuyStop(LotSize, buyStopPrice, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, "Buy Stop Order"))
   {
      buyStopTicket = trade.ResultOrder();
      Print("Buy Stop order placed. Ticket: ", buyStopTicket, ", Entry: ", buyStopPrice, ", Stop Loss: ", buySL, ", Take Profit: ", buyTP);
   }
   else
   {
      Print("Error placing Buy Stop order. Error code: ", GetLastError());
      return;
   }
   
   // Place Sell Stop order with initial stop loss
   if(trade.SellStop(LotSize, sellStopPrice, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, "Sell Stop Order"))
   {
      sellStopTicket = trade.ResultOrder();
      Print("Sell Stop order placed. Ticket: ", sellStopTicket, ", Entry: ", sellStopPrice, ", Stop Loss: ", sellSL, ", Take Profit: ", sellTP);
   }
   else
   {
      Print("Error placing Sell Stop order. Error code: ", GetLastError());
      // If Sell Stop fails, delete the Buy Stop
      if(buyStopTicket > 0)
         trade.OrderDelete(buyStopTicket);
      
      buyStopTicket = 0;
      return;
   }
   
   // If both orders placed successfully
   if(buyStopTicket > 0 && sellStopTicket > 0)
   {
      ordersPlaced = true;
   }
}

//+------------------------------------------------------------------+
//| Manage active trades and delete opposite pending order          |
//+------------------------------------------------------------------+
void ManageOrders()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong posTicket = PositionGetTicket(i);
      
      if(posTicket <= 0)
         continue;
      
      if(!PositionSelectByTicket(posTicket))
         continue;
      
      // Check if position belongs to current symbol
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      
      // Get position details
      long posType = PositionGetInteger(POSITION_TYPE);
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      double currentPrice;
      
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         // Delete opposite Sell Stop order if it exists
         if(sellStopTicket > 0)
         {
            if(OrderSelect(sellStopTicket))
            {
               trade.OrderDelete(sellStopTicket);
               sellStopTicket = 0;
               Print("Sell Stop order deleted after Buy position activated");
            }
         }
         
         // Move SL to lock profit when profit reaches trigger level
         double profitInPoints = (currentPrice - entryPrice) / _Point;
         double targetSL = NormalizeDouble(entryPrice + (ProfitLock * _Point), _Digits);
         
         if(profitInPoints >= ProfitTrigger && (stopLoss < targetSL || stopLoss < entryPrice))
         {
            trade.PositionModify(posTicket, targetSL, PositionGetDouble(POSITION_TP));
            Print("Buy position stop loss moved to lock ", ProfitLock, " points profit when profit reached ", ProfitTrigger, " points");
         }
         
         // Apply trailing stop
         if(profitInPoints >= TrailStart)
         {
            double newSL = NormalizeDouble(currentPrice - (TrailDistance * _Point), _Digits);
            
            // Only modify if new SL is higher than current one
            if(newSL > stopLoss)
            {
               trade.PositionModify(posTicket, newSL, PositionGetDouble(POSITION_TP));
               Print("Buy position trailing stop updated to: ", newSL);
            }
         }
         
         // Check for opposite breakout signal
         if(CloseOnOppositeSignal)
         {
            // If price goes below recent low, close buy position
            double recentLow = iLow(_Symbol, PERIOD_M1, iLowest(_Symbol, PERIOD_M1, MODE_LOW, 3, 1));
            if(currentPrice < recentLow)
            {
               trade.PositionClose(posTicket);
               Print("Buy position closed due to opposite breakout signal");
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // Delete opposite Buy Stop order if it exists
         if(buyStopTicket > 0)
         {
            if(OrderSelect(buyStopTicket))
            {
               trade.OrderDelete(buyStopTicket);
               buyStopTicket = 0;
               Print("Buy Stop order deleted after Sell position activated");
            }
         }
         
         // Move SL to lock profit when profit reaches trigger level
         double profitInPoints = (entryPrice - currentPrice) / _Point;
         double targetSL = NormalizeDouble(entryPrice - (ProfitLock * _Point), _Digits);
         
         if(profitInPoints >= ProfitTrigger && (stopLoss > targetSL || stopLoss > entryPrice))
         {
            trade.PositionModify(posTicket, targetSL, PositionGetDouble(POSITION_TP));
            Print("Sell position stop loss moved to lock ", ProfitLock, " points profit when profit reached ", ProfitTrigger, " points");
         }
         
         // Apply trailing stop
         if(profitInPoints >= TrailStart)
         {
            double newSL = NormalizeDouble(currentPrice + (TrailDistance * _Point), _Digits);
            
            // Only modify if new SL is lower than current one
            if(newSL < stopLoss || stopLoss == 0)
            {
               trade.PositionModify(posTicket, newSL, PositionGetDouble(POSITION_TP));
               Print("Sell position trailing stop updated to: ", newSL);
            }
         }
         
         // Check for opposite breakout signal
         if(CloseOnOppositeSignal)
         {
            // If price goes above recent high, close sell position
            double recentHigh = iHigh(_Symbol, PERIOD_M1, iHighest(_Symbol, PERIOD_M1, MODE_HIGH, 3, 1));
            if(currentPrice > recentHigh)
            {
               trade.PositionClose(posTicket);
               Print("Sell position closed due to opposite breakout signal");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if all trades are closed and reset orders                 |
//+------------------------------------------------------------------+
void CheckAndResetOrders()
{
   // Check if there are any active positions for this symbol
   bool hasPositions = false;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
               hasPositions = true;
               break;
            }
         }
      }
   }
   
   // Check if there are any pending orders for this symbol
   bool hasPendingOrders = false;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderSelect(ticket))
         {
            if(OrderGetString(ORDER_SYMBOL) == _Symbol)
            {
               hasPendingOrders = true;
               break;
            }
         }
      }
   }
   
   // Reset if no positions and no pending orders
   if(!hasPositions && !hasPendingOrders)
   {
      ordersPlaced = false;
      buyStopTicket = 0;
      sellStopTicket = 0;
      PlaceStopOrders();
      Print("All trades closed, placing new stop orders");
   }
}