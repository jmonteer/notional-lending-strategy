// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/notional/NotionalProxy.sol";
import "../interfaces/IWETH.sol";


// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

import {
    BalanceActionWithTrades,
    AccountContext,
    PortfolioAsset,
    AssetRateParameters,
    Token,
    ETHRate
} from "../interfaces/notional/Types.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // NotionalContract: proxy that points to a router with different implementations depending on function 
    NotionalProxy public immutable nProxy;
    // ID of the asset being lent in Notional
    uint16 private immutable currencyID; 
    // Difference of decimals between Notional system (8) and want
    uint256 private immutable DECIMALS_DIFFERENCE;
    // minimum amount of want to act on
    uint16 public minAmountWant;
    IWETH public constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Base for percentage calculations. BPS (10000 = 100%, 100 = 1%)
    uint256 private constant MAX_BPS = 10_000;

    constructor(address _vault, NotionalProxy _nProxy, uint16 _currencyID) public BaseStrategy(_vault) {
        currencyID = _currencyID;
        nProxy = _nProxy;

        (Token memory assetToken, Token memory underlying) = _nProxy.getCurrency(_currencyID);
        DECIMALS_DIFFERENCE = uint256(underlying.decimals).mul(MAX_BPS).div(uint256(assetToken.decimals));

        require(address(want) == underlying.tokenAddress); // dev: currencyID is not correct
    }

    // For ETH based strategies
    receive() external payable {}

    // TODO: add sweep function for ETH ? (only callable if want != weth)

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyNotionalLending";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // To estimate the assets under management of the strategy we add the want balance already 
        // in the contract and the current valuation of the non-matured positions (including the cost of)
        // closing the position early
        // This function is supposed to be called after _checkPositionsAndWithdraw() so the matured positions 
        // are supposed to already be included in the contract's want balance
        return balanceOfWant()
            .add(_getTotalValueFromPortfolio())
        ;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // Withdraw from terms that already matured
        _checkPositionsAndWithdraw();

        // We only need profit for decision making
        (_profit, ) = getUnrealisedPL();

        // free funds to repay debt + profit to the strategy
        uint256 wantBalance = balanceOfWant();
        uint256 amountRequired = _debtOutstanding.add(_profit);
        if(amountRequired > wantBalance) {
            // we need to free funds
            // NOTE: liquidatePosition will try to use balanceOfWant first
            // liquidatePosition will realise Losses if required !! (which cannot be equal to unrealised losses if
            // we are not withdrawing 100% of position)
            (uint256 amountAvailable, uint256 realisedLoss) = liquidatePosition(amountRequired);
            _loss = realisedLoss;

            if(amountAvailable >= amountRequired) {
                _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
                if(amountRequired.sub(_debtPayment) < _profit) {
                    _profit = amountRequired.sub(_debtPayment);
                }
            } else {
                // we were not able to free enough funds
                if(amountAvailable < _debtOutstanding) {
                    // available funds are lower than the repayment that we need to do
                    _profit = 0;
                    _debtPayment = amountAvailable;
                    // we dont report losses here as the strategy might not be able to return in this harvest
                    // but it will still be there for the next harvest
                } else {
                    // NOTE: amountRequired is always equal or greater than _debtOutstanding
                    // important to use amountRequired just in case amountAvailable is > amountAvailable
                    _debtPayment = _debtOutstanding;
                    _profit = amountAvailable.sub(_debtPayment);
                }
            }
        } else {
            _debtPayment = _debtOutstanding;
            // profit remains unchanged unless there is not enough to pay it
            if(amountRequired.sub(_debtPayment) < _profit) {
                _profit = amountRequired.sub(_debtPayment);
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 availableWantBalance = balanceOfWant();
        
        if(availableWantBalance <= _debtOutstanding) {
            return;
        }
        availableWantBalance = availableWantBalance.sub(_debtOutstanding);
        if(availableWantBalance < minAmountWant) {
            return;
        }
        
        // gas savings
        uint16 _currencyID = currencyID;
        if (_currencyID == 1) {
            // Only necessary for wETH/ ETH pair
            weth.withdraw(availableWantBalance);
        }

        // Use market index = 1 as we are looking to lend into the shortest maturity
        int256 fCashAmountToTrade = nProxy.getfCashAmountGivenCashAmount(
            _currencyID, 
            -int88(availableWantBalance.mul(MAX_BPS).div(DECIMALS_DIFFERENCE)), 
            1, 
            block.timestamp
            );

        require(fCashAmountToTrade > 0);

        // Trade the shortest maturity market
        bytes32[] memory trades = new bytes32[](1);
        trades[0] = getTradeFrom(
            0, 
            1, 
            uint256(fCashAmountToTrade)
            );

        executeBalanceActionWithTrades(
            DepositActionType.DepositUnderlying,
            availableWantBalance,
            0, 
            true,
            true,
            trades
        );
    }

    function getTradeFrom(uint8 _tradeType, uint256 _marketIndex, uint256 _amount) internal returns (bytes32 result) {
        uint8 tradeType = uint8(_tradeType);
        uint8 marketIndex = uint8(_marketIndex);
        uint88 fCashAmount = uint88(_amount);
        uint32 minSlippage = uint32(0);
        uint120 padding = uint120(0);

        // We create result of trade in a bitmap packed encoded bytes32
        result = bytes32(uint(tradeType)) << 248;
        result |= bytes32(uint(marketIndex) << 240);
        result |= bytes32(uint(fCashAmount) << 152);
        result |= bytes32(uint(minSlippage) << 120);

        return result;
    }

    function getUnrealisedPL() internal view returns (uint256 _unrealisedProfit, uint256 _unrealisedLoss) {
        // Calculate assets. This includes profit and cost of closing current position. 
        // Due to cost of closing position, If called just after opening the position, assets < invested want
        uint256 totalAssets = estimatedTotalAssets();
        // Get total debt from vault
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Calculate current P&L
        if(totalDebt > totalAssets) {
            // we have losses
            // Losses are unrealised until we close the position so we should not report them until realised
            _unrealisedLoss = totalDebt.sub(totalAssets);
        } else {
            // we have profit
            _unrealisedProfit = totalAssets.sub(totalDebt);
        }

    }


    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {

        // TODO: should we check if terms have finished? 
        // will be gas expensive but is correct

        // _checkPositionsAndWithdraw();

        uint256 wantBalance = balanceOfWant();
        if (wantBalance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Get current position's P&L
        (, uint256 unrealisedLosses) = getUnrealisedPL();

        // We only need to withdraw what we don't currently have
        uint256 amountToLiquidate = _amountNeeded.sub(wantBalance);
        // Losses are realised IFF we withdraw from the position, as they will come from breaking our "promise"
        // of lending at a certain %
        // The strategy will only realise losses proportional to the amount we are liquidating
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 lossesToBeRealised = unrealisedLosses.mul(amountToLiquidate).div(totalDebt.sub(wantBalance));
        // Due to how Notional works, we need to substract losses from the amount to liquidate
        // If we don't do this and withdraw a small enough % of position, we will not incur in losses,
        // leaving them for the future withdrawals (which is bad! those who withdraw should take the losses)
        amountToLiquidate = amountToLiquidate.sub(lossesToBeRealised);

        // Retrieve info of portfolio (summary of our position/s)
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        // The maximum amount of trades we are doing is the number of terms (aka markets) we are in
        bytes32[] memory trades = new bytes32[](_accountPortfolio.length);

        // To liquidate the full required amount we may need to liquidate several differents terms
        // This shouldn't happen in the basic strategy (as we will only lend to the shortest term)
        uint256 remainingAmount = amountToLiquidate;
        // The following for-loop creates the list of required trades to get the amountRequired
        for(uint256 i = 0; i < _accountPortfolio.length; i++) {
            if (remainingAmount > 0) {
                uint256 _marketIndex = _getMarketIndexForMaturity(
                    _accountPortfolio[i].maturity,
                    _activeMarkets
                );
                // Retrieve size of position in this market (underlyingInternalNotation)
                (, int256 underlyingInternalNotation) = nProxy.getCashAmountGivenfCashAmount(
                    currencyID,
                    int88(-_accountPortfolio[i].notional),
                    _marketIndex,
                    block.timestamp
                );
                // ADjust for decimals (Notional uses 8 decimals regardless of underlying)
                uint256 underlyingPosition = uint256(underlyingInternalNotation).mul(DECIMALS_DIFFERENCE).div(MAX_BPS);
                // If we can withdraw what we need from this market, we do and stop iterating over markets
                // If we can, we create the trade to withdraw maximum amount and try in the next market / term
                if(underlyingPosition >= remainingAmount) {
                    trades[i] = getTradeFrom(1, _marketIndex, 
                                             remainingAmount.mul(uint256(_accountPortfolio[i].notional)).div(underlyingPosition)
                                            );
                    remainingAmount = 0;
                    break;
                } else {
                    trades[i] = getTradeFrom(1, _marketIndex, uint256(_accountPortfolio[i].notional));
                    remainingAmount -= underlyingPosition;
                }
            }
        }
        // NOTE: if for some reason we reach this with remainingAmount > 0, we will report losses !
        // this makes sense because means we have iterated over all markets and haven't been able to withdraw

        // Execute previously calculated trades
        // We won't deposit anything (we are withdrawing) and we signal that we want the underlying to hit the strategy (instead of remaining in our Notional account)
        executeBalanceActionWithTrades(
            DepositActionType.None, 
            0,
            0, 
            true,
            true,
            trades
        );

        // Assess result 
        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            // _loss should be equal to lossesToBeRealised ! 
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: does it make sense to call liquidatePosition(max)? (so we can reuse code)
        // (uint256 amountLiquidated, ) = liquidateAmount(all);
        // return amountLiquidated;
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        bytes32[] memory trades = new bytes32[](_accountPortfolio.length);

        for(uint256 i=0; i<_accountPortfolio.length; i++) {
            
            uint256 _marketIndex = _getMarketIndexForMaturity(
                _accountPortfolio[i].maturity,
                _activeMarkets    
            );

            (int256 cashPosition, int256 underlyingPosition) = nProxy.getCashAmountGivenfCashAmount(
                currencyID,
                int88(-_accountPortfolio[i].notional),
                _marketIndex,
                block.timestamp
            );
            trades[i] = getTradeFrom(1, _marketIndex, uint256(_accountPortfolio[i].notional));
                    
        }

        executeBalanceActionWithTrades(
            DepositActionType.None,
            0,
            0, 
            true,
            true,
            trades
        );
        
        return want.balanceOf(address(this));
    }
    // DEBUGGING FUNCTIONS:
    // TODO: remove these
    function _liquidateAll() public {
        liquidateAllPositions();
    }

    function _liquidate(uint256 _amountNeeded) public returns (uint256 _liquidatedAmount, uint256 _loss){
        (_liquidatedAmount, _loss) = liquidatePosition(_amountNeeded);
    }

    // END OF DEBUGGING FUNCTIONS

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return _fromETH(_amtInWei, address(want));
    }

    function _fromETH(uint256 _amount, address asset)
        internal
        view
        returns (uint256)
    {
        if (
            _amount == 0 ||
            _amount == type(uint256).max ||
            address(asset) == address(weth) // 1:1 change
        ) {
            return _amount;
        }

        (
            Token memory assetToken,
            Token memory underlyingToken,
            ETHRate memory ethRate,
            AssetRateParameters memory assetRate
        ) = nProxy.getCurrencyAndRates(currencyID);
            
        return _amount.mul(uint256(underlyingToken.decimals)).div(uint256(ethRate.rate));
    }

    // INTERNAL FUNCTIONS

    function _checkPositionsAndWithdraw() internal {
        // We check if there is anything to settle in the account's portfolio by checking the account's
        // nextSettleTime in the account context
        AccountContext memory _accountContext = nProxy.getAccountContext(address(this));

        // If there is something to settle, do it and withdraw to the strategy's balance
        if (uint256(_accountContext.nextSettleTime) < block.timestamp) {
            nProxy.settleAccount(address(this));

            (int256 cashBalance, 
            int256 nTokenBalance,
            uint256 lastClaimTime) = nProxy.getAccountBalance(currencyID, address(this));

            if(cashBalance > 0) {
                nProxy.withdraw(currencyID, uint88(cashBalance), true);
            }
        }

    }

    function _getTotalValueFromPortfolio() internal view returns(uint256 _totalWantValue) {
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        // Iterate over all active markets and sum value of each position 
        for(uint256 i = 0; i < _accountPortfolio.length; i++) {
            for(uint256 j = 0; j < _activeMarkets.length; j++){
                if(_accountPortfolio[i].maturity == _activeMarkets[j].maturity) {
                    (, int256 underlyingPosition) = nProxy.getCashAmountGivenfCashAmount(
                        currencyID,
                        int88(-_accountPortfolio[i].notional),
                        j+1,
                        block.timestamp
                    );
                    _totalWantValue += uint256(underlyingPosition).mul(DECIMALS_DIFFERENCE).div(MAX_BPS);
                    break;
                }
            }
        }
    }

    // CALCS
    // TODO: Public for debugging make internal after
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _getMarketIndexForMaturity(
        uint256 _maturity, 
        MarketParameters[] memory _activeMarkets
    ) internal view returns(uint256) {
        bool success = false;
        for(uint256 j=0; j<_activeMarkets.length; j++){
            if(_maturity == _activeMarkets[j].maturity) {
                return j+1;
            }
        }
        // TODO: change to non-locking error !! 
        require(success, "No active market found for the required maturity");
    }

    // NOTIONAL FUNCTIONS
    function executeBalanceActionWithTrades(
        DepositActionType actionType,
        uint256 depositActionAmount,
        uint256 withdrawAmountInternalPrecision,
        bool withdrawEntireCashBalance,
        bool redeemToUnderlying,
        bytes32[] memory trades) internal {
        BalanceActionWithTrades[] memory actions = new BalanceActionWithTrades[](1);
        // gas savings
        uint16 _currencyID = currencyID;
        actions[0] = BalanceActionWithTrades(
            actionType,
            _currencyID,
            depositActionAmount,
            withdrawAmountInternalPrecision, 
            withdrawEntireCashBalance,
            redeemToUnderlying,
            trades
        );

        if (_currencyID == 1) {
            nProxy.batchBalanceAndTradeAction{value: depositActionAmount}(address(this), actions);
        } else {
            nProxy.batchBalanceAndTradeAction(address(this), actions);
        }
    }

}
