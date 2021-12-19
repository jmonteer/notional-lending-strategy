// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/notional/NotionalProxy.sol";


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

import {
    BalanceActionWithTrades
} from "../interfaces/notional/Types.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    NotionalProxy public immutable nProxy;
    uint16 private immutable currencyID; 
    uint16 public minAmountWant;

    constructor(address _vault, NotionalProxy _nProxy) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        currencyID = 2;
        nProxy = _nProxy;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyNotionalLending";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // TODO: check value of lent amount (using Account)
        // TODO: add want

        // OPTIONAL:
        // TODO: calculate how much would it cost to close NOW
        // TODO: check value of profits (and decide if we want to include it here)

        return want.balanceOf(address(this));
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
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        // TODO: withdraw from past terms

        // TODO: calc assets (estimatedTotalAssets)
        // TODO: calc debt vault.strategies(address(this)).totalDebt;

        // TODO: calc P&L: assets - debt ==> profit, loss

        // TODO: how much do i need to return (amountRequired = debtOutstanding + profit)
        // TODO: check if I have enough want to serve debtOutstanding
        // TODO: amountToLiquidate (amountRequired - balanceOfWant)
        // TODO: liquidatedAmount, loss = liquidatePosition(amountToLiquidate)


        // TODO: report loss, profit, debtPayment
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // TODO: check if we have invested in past terms
        // probably we need to check if we have a previous term we can take funds from

        uint256 availableWantBalance = balanceOfWant();
        if(availableWantBalance <= _debtOutstanding) {
            return;
        }
        availableWantBalance = availableWantBalance.sub(_debtOutstanding);
        if(availableWantBalance < minAmountWant) {
            return;
        }

        // TODO: getActiveMarketIndex for every 
        MarketParameters[] memory marketParameters = nProxy.getActiveMarkets(currencyID);
        uint256 marketIndex = 1;

        BalanceActionWithTrades[] memory actions = new BalanceActionWithTrades[](1);
        
        // TODO: term (initially always shortest one)
        // TODO: calculate marketIndex taking into account currency and term
        bytes32[] memory trades;
        trades[0] = getTradeFrom(marketIndex, availableWantBalance);

        actions[0] = BalanceActionWithTrades(
            DepositActionType.DepositUnderlying,
            currencyID,
            availableWantBalance,
            0, // TODO: review this
            true, // TODO: review this
            true, // TODO: review this
            trades);

        // TODO: check return value
        nProxy.batchBalanceAndTradeAction(address(this), actions);
    }

    function getTradeFrom(uint256 marketIndex, uint256 amount) internal returns (bytes32 trade) {
        // TODO: replicate remix test
        return bytes32(0);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        // TODO: balanceOFWant shortcut

        // TODO: calcualte amount of fCash that you need to sell
        // TODO: sell fCash for underlying (want)

        // TODO: assess result 

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        // TODO: Liquidate all positions and return the amount freed.
        return want.balanceOf(address(this));
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
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
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    // INTERNAL FUNCTIONS

    // CALCS
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // NOTIONAL FUNCTIONS

}
