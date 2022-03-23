from utils import actions, checks, utils
import pytest
from brownie import reverts

# tests harvesting a strategy that returns profits correctly
def test_clone(
    chain, accounts, token, vault, strategy, cloned_strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, ONEk_WANT
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount);

    # Check that strategy cannot be initialized twice
    with reverts():
        strategy.initialize(
            vault, 
            strategist, 
            strategist, 
            strategist, 
            n_proxy_views.address, 
            currencyID,
            ONEk_WANT, {"from": gov})
    # Check that cloned strategy cannot be initialized twice
    with reverts():
        cloned_strategy.initialize(
            vault, 
            strategist, 
            strategist, 
            strategist, 
            n_proxy_views.address, 
            currencyID,
            ONEk_WANT, {"from": gov})

    # Check both strategies
    assert strategy.currencyID() == cloned_strategy.currencyID()
    assert strategy.address != cloned_strategy.address

    # Check harvesting into the clone
    chain.sleep(1)
    tx = cloned_strategy.harvest({"from": gov})
    amount_invested = vault.strategies(cloned_strategy)["totalDebt"]

    account = n_proxy_views.getAccount(cloned_strategy)
    
    # Check wether we have entered into a position
    assert account["portfolio"][0][3] > 0

    # Sleep until maturity so the user can withdraw without reaching max_loss from the vault
    chain.sleep(account[0][0] - chain.time() + 1)
    chain.mine(1)

    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    cloned_strategy.setDoHealthCheck(False, {"from": gov})
    vault.updateStrategyDebtRatio(cloned_strategy, 0, {"from": gov})
    tx = cloned_strategy.harvest({"from": gov})

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
