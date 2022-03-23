
import pytest
from utils import actions, checks, utils


def test_migration(
    chain,
    token,
    vault,
    strategy,
    amount,
    Strategy,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    notional_proxy, 
    currencyID,
    n_proxy_views,
    ONEk_WANT
):  
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    amount_invested = vault.strategies(strategy)["totalDebt"]
    
    first_assets = strategy.estimatedTotalAssets()
    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, ONEk_WANT)

    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert new_strategy.estimatedTotalAssets() >= first_assets
    assert strategy.estimatedTotalAssets() == 0

    account = n_proxy_views.getAccount(new_strategy)
    next_settlement = account[0][0]

    chain.sleep(next_settlement - chain.time() + 1)
    chain.mine(1)

    new_new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, ONEk_WANT)
    vault.migrateStrategy(new_strategy, new_new_strategy, {"from": gov})

    assert new_strategy.estimatedTotalAssets() == 0
    assert strategy.estimatedTotalAssets() == 0
    assert new_new_strategy.estimatedTotalAssets() > amount_invested

    vault.updateStrategyDebtRatio(new_new_strategy, 0, {"from": gov})
    # check that harvest work as expected
    tx = new_new_strategy.harvest({"from": gov})

    assert tx.events["Harvested"]["profit"] > 0

    chain.sleep(3600 * 6)
    chain.mine(1)


    assert token.balanceOf(vault) > amount_invested



