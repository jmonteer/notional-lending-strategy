import pytest
from brownie import chain, accounts
import utils
from eth_abi.packed import encode_abi_packed

# This file is reserved for standard actions like deposits
def user_deposit(user, vault, token, amount):
    if token.allowance(user, vault) < amount:
        token.approve(vault, 2 ** 256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount


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


def whale_drop_rates(n_proxy_batch, whale, token, n_proxy_views, currencyID, balance_threshold):

    balance = token.balanceOf(whale)
    if(currencyID == 1):
        balance = accounts.at(whale, force=True).balance()

    if (balance > balance_threshold[0]):

        fcash_amount = n_proxy_views.getfCashAmountGivenCashAmount(currencyID, balance_threshold[1],
         1, 
         chain.time()+5)
        trade = encode_abi_packed(
            ["uint8", "uint8", "uint88", "uint32", "uint120"], 
            [0, 1, fcash_amount, 0, 0]
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

def whale_exit(n_proxy_batch, whale, n_proxy_views, currencyID):
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
