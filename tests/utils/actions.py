import pytest
from brownie import chain, accounts
import utils
from eth_abi.packed import encode_abi_packed

# This file is reserved for standard actions like deposits
def user_deposit(user, vault, token, amount):
    if token.allowance(user, vault) < amount:
        token.approve(vault, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) >= amount


def wait_until_settlement(next_settlement):
    delta = next_settlement - chain.time()
    if (delta > 86400):
        chain.sleep(delta - 86400)
    else:
        chain.sleep(delta)
    chain.mine(1)
    return

def wait_half_until_settlement(next_settlement):
    delta = next_settlement - chain.time()
    chain.sleep(int(delta / 2))
    chain.mine(1)
    return


def whale_drop_rates(n_proxy_batch, whale, token, n_proxy_views, currencyID, balance_threshold, market_index):

    balance = token.balanceOf(whale)
    if(currencyID == 1):
        balance = accounts.at(whale, force=True).balance()

    if (balance > balance_threshold[0]):

        fcash_amount = n_proxy_views.getfCashAmountGivenCashAmount(currencyID, balance_threshold[1],
         market_index, 
         chain.time()+5)
        trade = encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint120"], 
            [0, market_index, fcash_amount, 0, 0]
        )
        if(currencyID == 1):
            n_proxy_batch.batchBalanceAndTradeAction(whale, \
            [(2, currencyID, balance_threshold[0], 0, 1, 1,\
                [trade])], \
                    {"from": whale,\
                        "value":balance_threshold[0]})
        else:
            token.approve(n_proxy_views.address, balance_threshold[0], {"from": whale})
            n_proxy_batch.batchBalanceAndTradeAction(whale, \
            [(2, currencyID, balance_threshold[0], 0, 1, 1,\
                [trade])], \
                    {"from": whale,\
                        "value":0})
    else:
        raise("Whale does not have enough tokens")

    return

def whale_exit(n_proxy_batch, whale, n_proxy_views, currencyID, market_index):
    fcash_position = n_proxy_views.getAccount(whale)[2][0][3]
    trade = encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint120"], 
            [1, 1, fcash_position, 0, 0]
        )
    n_proxy_batch.batchBalanceAndTradeAction(whale, \
        [(0, currencyID, 0, 0, 1, 1,\
            [trade])], \
                {"from": whale,\
                     "value":0})
    return


def first_deposit_and_harvest(
    vault, strategy, token, user, gov, amount, RELATIVE_APPROX
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    utils.sleep()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

def initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
    next_settlement, n_proxy_batch, token, token_whale, n_proxy_account, million_in_token):
    if next_settlement - chain.time() > 86400 * 90:
        for (i, market) in enumerate(n_proxy_views.getActiveMarkets(currencyID)):
            if market[1] < next_settlement:
                chain.sleep(market[1] - chain.time() + 1)
                chain.mine(1)
                n_proxy_implementation.initializeMarkets(currencyID, 0, {"from": user})
                if currencyID == 2 or currencyID == 3:
                    buy_residuals(n_proxy_batch, n_proxy_implementation, currencyID, million_in_token, token, token_whale)

def buy_residuals(n_proxy_batch, n_proxy_implementation, currencyID, million_in_token, token, token_whale):
    token_whale_balance = token.balanceOf(token_whale)
    token.approve(n_proxy_implementation.address, 2 ** 256 - 1, {"from":token_whale})
    (liquidityTokens, fCash) = n_proxy_implementation.getNTokenPortfolio(n_proxy_implementation.nTokenAddress(currencyID))
    chain.mine(1, timestamp=chain.time() + 86400)
    trade = encode_abi_packed(["uint8", "uint32", "int88", "uint128"],[4, fCash[2][1], fCash[2][3], 0])
    n_proxy_batch.batchBalanceAndTradeAction(token_whale, \
        [(2,currencyID,million_in_token,0,0,0,\
            [trade])], \
                {"from": token_whale,\
                     "value":0})
    
