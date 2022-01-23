from utils import actions, checks, utils
import pytest

# tests harvesting a strategy that returns profits correctly
def test_clone(
    chain, accounts, token, vault, strategy, cloned_strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount);

    # Check both strategies
    assert strategy.currencyID() == cloned_strategy.currencyID()
    assert strategy.address != cloned_strategy.address

    # Check harvesting into the clone
    chain.sleep(1)
    tx = cloned_strategy.harvest({"from": gov})

    account = n_proxy_views.getAccount(cloned_strategy)
    
    # Check wether we have entered into a position
    assert account["portfolio"][0][3] > 0

    # Sleep until maturity so the user can withdraw without reaching max_loss from the vault
    chain.sleep(account[0][0] - chain.time() + 1)
    chain.mine(1)
