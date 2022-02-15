
import pytest
from utils import actions, checks, utils

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
    MAX_BPS,
    ONEk_WANT
):
    # Deposit to the vault and harvest
    actions.user_deposit(user, vault, token, amount)

    chain.sleep(1)
    strategy.harvest({"from": gov})
    amount_invested = vault.strategies(strategy)["totalDebt"]
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    first_assets = strategy.estimatedTotalAssets()
    # migrate to a new strategy
    new_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, ONEk_WANT)
    
    chain.mine(1, timedelta= 86_400)

    account = n_proxy_views.getAccount(strategy)
    liquidate_half = int(amount_invested/2) - token.balanceOf(strategy)
    fCash_to_close = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        -liquidate_half / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()+1
        )


    tx = strategy.liquidateWantAmount(liquidate_half, {"from":gov})
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

def test_force_liquidations(
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
    account = n_proxy_views.getAccount(strategy)
    fCash_balance = account[2][0][3]
    fCash_to_close = int(fCash_balance / 10)

    chain.mine(1, timedelta=3*86_400)

    tx = strategy.liquidatefCashAmount(min_market_index, fCash_to_close, {"from": gov})
    new_account = n_proxy_views.getAccount(strategy)

    assert (fCash_balance - new_account[2][0][3]) == fCash_to_close

    chain.mine(1, timedelta=2*86_400)
    tx = strategy.liquidatefCashAmount(min_market_index, (fCash_balance - fCash_to_close), {"from":gov})
    new_account = n_proxy_views.getAccount(strategy)

    assert new_account[2] == []

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    strategy.setToggleRealizeLosses(True, {"from":gov})
    strategy.setDoHealthCheck(False, {"from":gov})

    tx = strategy.harvest({"from":gov})
    chain.mine(1, timedelta=6 * 3_600)

    vault.withdraw({"from": user})

def test_emergency_exit(
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
    

    chain.mine(1, timedelta=3*86_400)

    first_assets = strategy.estimatedTotalAssets()
    strategy.setDoHealthCheck(False, {"from":gov})
    strategy.setEmergencyExit({"from":gov})

    tx = strategy.harvest({"from":gov})

    account = n_proxy_views.getAccount(strategy)
    assert account[2] == []

    assert token.balanceOf(strategy) == 0

    chain.mine(1, timedelta=6*3_600)
    vault.withdraw({"from": user})
    