// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// Necessary interfaces to:
// 1) interact with the Notional protocol
import "../interfaces/notional/NotionalProxy.sol";
// 2) Transact between WETH (Vault) and ETH (Notional)
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

// Import the necessary structs to send/ receive data from Notional
import {
    BalanceActionWithTrades,
    AccountContext,
    PortfolioAsset,
    AssetRateParameters,
    Token,
    ETHRate
} from "../interfaces/notional/Types.sol";

/*
     * @notice
     *  Yearn Strategy allocating vault's funds to a fixed rate lending market within the Notional protocol
*/
contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // NotionalContract: proxy that points to a router with different implementations depending on function 
    NotionalProxy public nProxy;
    // ID of the asset being lent in Notional
    uint16 public currencyID; 
    // Difference of decimals between Notional system (8) and want
    uint256 public DECIMALS_DIFFERENCE;
    // Scaling factor for entering positions as the fcash estimations have rounding errors
    uint256 internal constant FCASH_SCALING = 9_995;
    // minimum maturity for the market to enter
    uint256 private minTimeToMaturity;
    // minimum amount of want to act on
    uint16 public minAmountWant;
    // Initialize WETH interface
    IWETH public constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    // Constant necessary to accept ERC1155 fcash tokens (for migration purposes) 
    bytes4 internal constant ERC1155_ACCEPTED = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    // To control when positions should be liquidated before maturity or not (and thus incur in losses)
    bool internal toggleRealizeLosses;
    // Base for percentage calculations. BPS (10000 = 100%, 100 = 1%)
    uint256 private constant MAX_BPS = 10_000;
    // Current maturity invested
    uint256 private maturity;

    // EVENTS
    event Cloned(address indexed clone);

    /*
     * @notice constructor for the contract, called at deployment, calls the initializer function used for 
     * cloning strategies
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     */
    constructor(
        address _vault,
        NotionalProxy _nProxy,
        uint16 _currencyID    
    ) public BaseStrategy (_vault) {
        _initializeNotionalStrategy(_nProxy, _currencyID);
    }

    /*
     * @notice Initializer function to initialize both the BaseSrategy and the Notional strategy 
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _strategist Strategist managing the strategy
     * @param _rewards Rewards address
     * @param _keeper Keeper address
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     */
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        NotionalProxy _nProxy,
        uint16 _currencyID
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeNotionalStrategy(_nProxy, _currencyID);
    }

    /*
     * @notice Internal initializer for the Notional Strategy contract
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     */
    function _initializeNotionalStrategy (
        NotionalProxy _nProxy,
        uint16 _currencyID
    ) internal {
        currencyID = _currencyID;
        nProxy = _nProxy;

        (Token memory assetToken, Token memory underlying) = _nProxy.getCurrency(_currencyID);
        DECIMALS_DIFFERENCE = uint256(underlying.decimals).mul(MAX_BPS).div(uint256(assetToken.decimals));
        
        // By default do not realize losses
        toggleRealizeLosses = false;

        // Check whether the currency is set up right
        if (_currencyID == 1) {
            require(address(0) == underlying.tokenAddress); 
        } else {
            require(address(want) == underlying.tokenAddress);
        }
    }

    /*
     * @notice Cloning function to re-use the strategy code and deploy the same strategy with other key parameters,
     * notably currencyID or yVault
     * @param _vault Address of the corresponding vault the contract reports to
     * @param _strategist Strategist managing the strategy
     * @param _rewards Rewards address
     * @param _keeper Keeper address
     * @param _nProxy Notional proxy used to interact with the protocol
     * @param _currencyID Notional identifier of the currency (token) the strategy interacts with:
     * 1 - ETH
     * 2 - DAI
     * 3 - USDC
     * 4 - WBTC
     */
    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        NotionalProxy _nProxy,
        uint16 _currencyID
    ) external returns (address payable newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _nProxy, _currencyID);

        emit Cloned(newStrategy);
    }

    // For ETH based strategies
    receive() external payable {}

    /*
     * @notice
     *  Sweep function only callable by governance to be able to sweep any ETH assigned to the strategy's balance
     */
    function sendETHToGovernance() external onlyGovernance {
        (bool sent, bytes memory data) = governance().call{value: address(this).balance}("");
        require(sent, "Failed to send Ether");
    }

    /*
     * @notice
     *  Getter function for the name of the strategy
     * @return string, the name of the strategy
     */
    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyNotionalLending";
    }
    
    /*
     * @notice
     *  Getter function for the current invested maturity
     * @return uint256, current maturity we are invested in
     */
    function getMaturity() external view returns(uint256) {
        return maturity;
    }

    /*
     * @notice
     *  Getter function for the toggle defining whether to realize losses or not
     * @return bool, current toggleRealizeLosses state variable
     */
    function getToggleRealizeLosses() external view returns(bool) {
        return toggleRealizeLosses;
    }

    /*
     * @notice
     *  Setter function for the toggle defining whether to realize losses or not
     * @param _newToggle, new booelan value for the toggle
     */
    function setToggleRealizeLosses(bool _newToggle) external onlyEmergencyAuthorized {
        toggleRealizeLosses = _newToggle;
    }
    
    /*
     * @notice
     *  Getter function for the minimum time to maturity to invest into
     * @return uint256, current minTimeToMaturity state variable
     */
    function getMinTimeToMaturity() external view returns(uint256) {
        return minTimeToMaturity;
    }

    /*
     * @notice
     *  Setter function for the minimum time to maturity to invest into, accesible only to governance
     * @param _newTime, new minimum time to maturity to invest into
     */
    function setMinTimeToMaturity(uint256 _newTime) external onlyEmergencyAuthorized {
        minTimeToMaturity = _newTime;
    }

    /*
     * @notice
     *  Setter function for the minimum amount of want to invest, accesible only to governance
     * @param _newMinAmount, new minimum amount of want to invest
     */
    function setMinAmountWant(uint16 _newMinAmount) external onlyEmergencyAuthorized {
        minAmountWant = _newMinAmount;
    }

    /*
     * @notice
     *  Function estimating the total assets under management of the strategy, whether realized (token balances
     * of the contract) or unrealized (as Notional lending positions)
     * @return uint256, value containing the total AUM valuation
     */
    function estimatedTotalAssets() public view override returns (uint256) {
        // To estimate the assets under management of the strategy we add the want balance already 
        // in the contract and the current valuation of the matured and non-matured positions (including the cost of)
        // closing the position early

        return balanceOfWant()
            .add(_getTotalValueFromPortfolio())
        ;
    }

    /*
     * @notice
     *  Accounting function preparing the reporting to the vault taking into acccount the standing debt
     * @param _debtOutstanding, Debt still left to pay to the vault
     * @return _profit, the amount of profits the strategy may have produced until now
     * @return _loss, the amount of losses the strategy may have produced until now
     * @return _debtPayment, the amount the strategy has been able to pay back to the vault
     */
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
        
        // If we cannot realize the profit using want balance, don't report a profit to avoid
        // closing active positions before maturity
        if (_profit > wantBalance) {
            _profit = 0;
        }
        uint256 amountRequired = _debtOutstanding.add(_profit);
        if(amountRequired > wantBalance) {
            // we need to free funds
            // NOTE: liquidatePosition will try to use balanceOfWant first
            // liquidatePosition will realise Losses if required !! (which cannot be equal to unrealised losses if
            // we are not withdrawing 100% of position)
            uint256 amountAvailable = 0;
            uint256 realisedLoss = 0;

            // If the toggle to realize losses is off, do not close any position
            if(toggleRealizeLosses) {
                (amountAvailable, realisedLoss) = liquidatePosition(amountRequired);
            }
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

    /*
     * @notice
     * Function re-allocating the available funds (present in the strategy's balance in the 'want' token)
     * into new positions in Notional
     * @param _debtOutstanding, Debt still left to pay to the vault
     */
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
        uint256 _maturity = maturity;

        // Use the market index with the shortest maturity
        (uint256 minMarketIndex, uint256 minMarketMaturity) = _getMinimumMarketIndex();
        // If the new position enters a different market than the current maturity, roll the current position into
        // the next maturity market
        if(minMarketMaturity > _maturity && _maturity > 0) {
            availableWantBalance += _rollOverTrade(_maturity);
        }

        if (_currencyID == 1) {
            // Only necessary for wETH/ ETH pair
            weth.withdraw(availableWantBalance);
        } else {
            want.approve(address(nProxy), availableWantBalance);
        }
        // Amount to trade is the available want balance, changed to 8 decimals and
        // scaled down by FCASH_SCALING to ensure it does not revert
        int88 amountTrade = int88(
                availableWantBalance.mul(MAX_BPS).div(DECIMALS_DIFFERENCE).mul(FCASH_SCALING).div(MAX_BPS)
            );
        // NOTE: May revert if the availableWantBalance is too high and interest rates get to < 0
        int256 fCashAmountToTrade = nProxy.getfCashAmountGivenCashAmount(
            _currencyID, 
            -amountTrade, 
            minMarketIndex, 
            block.timestamp
            );

        if (fCashAmountToTrade <= 0) {
            return;
        }

        // Trade the shortest maturity market with at least minAmountToMaturity time left
        bytes32[] memory trades = new bytes32[](1);
        trades[0] = getTradeFrom(
            0, 
            minMarketIndex, 
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

        maturity = minMarketMaturity;
    }

    /*
     * @notice
     *  Internal function encoding a trade parameter into a bytes32 variable needed for Notional
     * @param _tradeType, Identification of the trade to perform, following the Notional classification in enum 'TradeActionType'
     * @param _marketIndex, Market index in which to trade into
     * @param _amount, fCash amount to trade
     * @return bytes32 result, the encoded trade ready to be used in Notional's 'BatchTradeAction'
     */
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
    
    /*
     * @notice
     *  Internal function to assess the unrealised P&L of the Notional's positions
     * @return uint256 result, the encoded trade ready to be used in Notional's 'BatchTradeAction'
     */
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

    /*
     * @notice
     *  Internal function liquidating enough Notional positions to liberate _amountNeeded 'want' tokens
     * @param _amountNeeded, The total amount of tokens needed to pay the vault back
     * @return uint256 _liquidatedAmount, Amount freed
     * @return uint256 _loss, Losses incurred due to early closing of positions
     */
    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _checkPositionsAndWithdraw();

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
        // The maximum amount of trades we are doing is the number of terms (aka markets) we are in
        bytes32[] memory trades = new bytes32[](_accountPortfolio.length);

        // To liquidate the full required amount we may need to liquidate several differents terms
        // This shouldn't happen in the basic strategy (as we will only lend to the shortest term)
        uint256 remainingAmount = amountToLiquidate;
        // The following for-loop creates the list of required trades to get the amountRequired
        uint256 tradesToExecute = 0;
        for(uint256 i; i < _accountPortfolio.length; i++) {
            if (remainingAmount > 0) {
                uint256 _marketIndex = _getMarketIndexForMaturity(
                    _accountPortfolio[i].maturity
                );
                // Retrieve size of position in this market (underlyingInternalNotation)
                (, int256 underlyingInternalNotation) = nProxy.getCashAmountGivenfCashAmount(
                    currencyID,
                    int88(-_accountPortfolio[i].notional),
                    _marketIndex,
                    block.timestamp
                );
                // Adjust for decimals (Notional uses 8 decimals regardless of underlying)
                uint256 underlyingPosition = uint256(underlyingInternalNotation).mul(DECIMALS_DIFFERENCE).div(MAX_BPS);
                // If we can withdraw what we need from this market, we do and stop iterating over markets
                // If we can't, we create the trade to withdraw maximum amount and try in the next market / term
                if(underlyingPosition > remainingAmount) {
                    
                    int256 fCashAmountToTrade = -nProxy.getfCashAmountGivenCashAmount(
                        currencyID, 
                        int88(remainingAmount.mul(MAX_BPS).div(DECIMALS_DIFFERENCE)) + 1, 
                        _marketIndex, 
                        block.timestamp
                        );
                    trades[i] = getTradeFrom(1, _marketIndex, 
                                            uint256(fCashAmountToTrade)
                                            );
                    tradesToExecute++;
                    remainingAmount = 0;
                    break;
                } else {
                    trades[i] = getTradeFrom(1, _marketIndex, uint256(_accountPortfolio[i].notional));
                    tradesToExecute++;
                    remainingAmount -= underlyingPosition;
                    maturity = 0;
                }
            }
        }
        // NOTE: if for some reason we reach this with remainingAmount > 0, we will report losses !
        // this makes sense because means we have iterated over all markets and haven't been able to withdraw

        // As we did not know the number of trades we needed to make, we adjust the array to only include
        // non-empty trades (reverts otherwise)
        bytes32[] memory final_trades = new bytes32[](tradesToExecute);
        for (uint256 j=0; j<tradesToExecute; j++) {
            final_trades[j] = trades[j];
        }

        // Execute previously calculated trades
        // We won't deposit anything (we are withdrawing) and we signal that we want the underlying to hit the strategy (instead of remaining in our Notional account)
        executeBalanceActionWithTrades(
            DepositActionType.None, 
            0,
            0, 
            true,
            true,
            final_trades
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

        // Re-set the toggle to false
        toggleRealizeLosses = false;
    }

    /*
     * @notice
     *  Internal function used in emergency to close all active positions and liberate all assets
     * @return uint256 amountLiquidated, the total amount liquidated
     */
    function liquidateAllPositions() internal override returns (uint256) {
        
        (uint256 amountLiquidated, ) = liquidatePosition(estimatedTotalAssets());

        return amountLiquidated;
    }
    
    /*
     * @notice
     *  Internal function used to migrate all 'want' tokens and active Notional positions to a new strategy
     * @param _newStrategy address where the contract of the new strategy is located
     */
    function prepareMigration(address _newStrategy) internal override {
        _checkPositionsAndWithdraw();
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));

        uint256 _id = 0;
        for(uint256 i = 0; i < _accountPortfolio.length; i++) {
            _id = nProxy.encodeToId(
                currencyID, 
                uint40(_accountPortfolio[i].maturity), 
                uint8(_accountPortfolio[i].assetType)
                );
            nProxy.safeTransferFrom(
                address(this), 
                _newStrategy,
                _id, 
                uint256(_accountPortfolio[i].notional),
                ""
                );
        }
        
    }

    /*
     * @notice
     *  Callback function needed to receive ERC1155 (fcash), not needed for the first startegy contract but 
     * relevant for all the next ones
     * @param _sender, address of the msg.sender
     * @param _from, address of the contract sending the erc1155
     * @_id, encoded id of the asset (fcash or liquidity token)
     * @_amount, amount of assets tor receive
     * _data, bytes calldata to perform extra actions after receiving the erc1155
     * @return bytes4, constant accepting the erc1155
     */
    function onERC1155Received(address _sender, address _from, uint256 _id, uint256 _amount, bytes calldata _data) public returns(bytes4){
        return ERC1155_ACCEPTED;
    }

    /*
     * @notice
     *  Define protected tokens for the strategy to manage persistently that will not get converted back
     * to 'want'
     * @return address result, the address of the tokens to protect
     */
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /*
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
     */
    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return _fromETH(_amtInWei, address(want));
    }

    /*
     * @notice
     *  Internal function exchanging between ETH to 'want'
     * @param _amount, Amount to exchange
     * @param asset, 'want' asset to exchange to
     * @return uint256 result, the equivalent ETH amount in 'want' tokens
     */
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

    /*
     * @notice
     *  Internal function used to check whether there are positions that have reached maturity and if so, 
     * settle and withdraw them realizing the profits in the strategy's 'want' balance
     */
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
                if (currencyID == 1) {
                    // Only necessary for wETH/ ETH pair
                    weth.deposit{value: address(this).balance}();
                }
                maturity = 0;
            }
        }

    }

    /*
     * @notice
     *  Loop through the strategy's positions and convert the fcash to current valuation in 'want', including the
     * fees incurred by leaving the position early. Represents the NPV of the position today.
     * @return uint256 _totalWantValue, the total amount of 'want' tokens of the strategy's positions
     */
    function _getTotalValueFromPortfolio() internal view returns(uint256 _totalWantValue) {
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        // Iterate over all active markets and sum value of each position 
        for(uint256 i = 0; i < _accountPortfolio.length; i++) {
            for(uint256 j = 0; j < _activeMarkets.length; j++){
                if(_accountPortfolio[i].maturity < block.timestamp) {
                    // Convert the fcash amount of the position to underlying assuming a 1:1 conversion rate
                    // (taking into account decimals difference)
                    _totalWantValue += uint256(_accountPortfolio[i].notional).mul(DECIMALS_DIFFERENCE).div(MAX_BPS);
                    break;
                }
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
    /*
     * @notice
     *  Internal function getting the current 'want' balance of the strategy
     * @return uint256 result, strategy's 'want' balance
     */
    function balanceOfWant() internal view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /*
     * @notice
     *  Get the market index of a current position to calculate the real cash valuation
     * @param _maturity, Maturity of the position to value
     * @param _activeMarkets, All current active markets for the currencyID
     * @return uint256 result, market index of the position to value
     */
    function _getMarketIndexForMaturity(
        uint256 _maturity
    ) internal view returns(uint256) {
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        bool success = false;
        for(uint256 j=0; j<_activeMarkets.length; j++){
            if(_maturity == _activeMarkets[j].maturity) {
                return j+1;
            }
        }
        
        if (success == false) {
            return 0;
        }
    }

    /*
     * @notice
     *  Internal function calculating the market index with the shortest maturity that was at 
     * least minAmountToMaturity seconds still 
     * @return uint256 result, the minimum market index the strategy should be entering positions into
     * @return uint256 maturity, the minimum market index's maturity the strategy should be entering positions into
     */
    function _getMinimumMarketIndex() internal view returns(uint256, uint256) {
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        for(uint256 i = 0; i<_activeMarkets.length; i++) {
            if (_activeMarkets[i].maturity - block.timestamp >= minTimeToMaturity) {
                return (i+1, uint256(_activeMarkets[i].maturity));
            }
        }
    } 

    // NOTIONAL FUNCTIONS
    /*
     * @notice
     *  Internal function executing a 'batchBalanceAndTradeAction' within Notional to either Lend or Borrow
     * @param actionType, Identification of the action to perform, following the Notional classification 
     * in enum 'DepositActionType'
     * @param withdrawAmountInternalPrecision, withdraw an amount of asset cash specified in Notional 
     *  internal 8 decimal precision
     * @param withdrawEntireCashBalance, whether to withdraw entire cash balance. Useful if there may be
     * an unknown amount of asset cash residual left from trading
     * @param redeemToUnderlying, whether to redeem asset cash to the underlying token on withdraw
     * @param trades, array of bytes32 trades to perform
     */
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
            weth.deposit{value: address(this).balance}();
        } else {
            nProxy.batchBalanceAndTradeAction(address(this), actions);
        }
    }

    /*
     * @notice
     *  Internal function Closing a current non-mature position to re-invest the amount into a new 
     * higher maturity market
     * @param _currentMaturity, current maturity the strategy is invested in
     * @return uint256, liberated amount, now existing in want balance to add up to the availableWantBalance
     * to trade into in adjustPosition()
     */
    function _rollOverTrade(uint256 _currentMaturity) internal returns(uint256) {
        uint256 prevBalance = balanceOfWant();
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        uint256 _currentIndex = _getMarketIndexForMaturity(_currentMaturity);
        
        bytes32[] memory rollTrade = new bytes32[](1);
        rollTrade[0] = getTradeFrom(1, _currentIndex, uint256(_accountPortfolio[0].notional));
        executeBalanceActionWithTrades(
            DepositActionType.None, 
            0,
            0, 
            true,
            true,
            rollTrade
        );
        
        return (balanceOfWant() - prevBalance);
    }

}