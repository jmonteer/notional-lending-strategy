
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
    n_proxy_views
):  
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    amount_invested = vault.strategies(strategy)["totalDebt"]
    
    first_assets = strategy.estimatedTotalAssets()
    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID)

    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert new_strategy.estimatedTotalAssets() >= first_assets
    assert strategy.estimatedTotalAssets() == 0

    account = n_proxy_views.getAccount(new_strategy)
    next_settlement = account[0][0]

    chain.sleep(next_settlement - chain.time() + 1)
    chain.mine(1)

    new_new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID)
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

def test_force_migration(
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
    MAX_BPS
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    amount_invested = vault.strategies(strategy)["totalDebt"]
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    first_assets = strategy.estimatedTotalAssets()
    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID)
    
    chain.mine(1, timedelta= 86_400)

    account = n_proxy_views.getAccount(strategy)
    liquidate_half = int(amount_invested/2) - token.balanceOf(strategy)
    fCash_to_close = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        -liquidate_half / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()+1
        )


    tx = strategy.liquidateAmount(liquidate_half, {"from":gov})
    new_account = n_proxy_views.getAccount(strategy)

    assert pytest.approx((account[2][0][3] - new_account[2][0][3]), rel=RELATIVE_APPROX) == fCash_to_close

    strategy.transferMarket(
        new_strategy,
        new_account[2][0][1],
        new_account[2][0][2],
        new_account[2][0][3],
        {"from": gov}
    )

    account = n_proxy_views.getAccount(strategy)
    assert account[2] == []
    assert account[0][0] == 0

    trf_account = n_proxy_views.getAccount(new_strategy)
    assert trf_account[0][0] == new_account[0][0]
    assert trf_account[2][0][1] == new_account[2][0][1]

    chain.mine(1, timestamp=trf_account[0][0] + 1)

    new_strategy.checkPositionsAndWithdraw({"from":gov})
    account = n_proxy_views.getAccount(new_strategy)

    assert account[0][0] == 0
    assert account[2] == []

    strategy.setForceMigration(True, {"from": gov})
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})

    want_balance_end = token.balanceOf(new_strategy)

    assert want_balance_end > amount_invested

    chain.mine(1, timedelta=3_600 * 6)