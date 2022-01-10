pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/notional/NotionalProxy.sol";

contract NotionalImplementation {
    NotionalProxy public immutable nProxy;
    constructor(NotionalProxy _nProxy) public {
        nProxy = _nProxy;
    }

    function initializeMarkets(uint16 currencyId, bool isFirstInit) public {
        nProxy.initializeMarkets(currencyId, isFirstInit);
    }
}