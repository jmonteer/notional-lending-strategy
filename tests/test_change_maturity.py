from utils import actions, checks, utils
import pytest

# tests changing the minAmountToMaturity state variable
def test_change_maturity(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, token_whale, n_proxy_account,
    million_in_token, gov
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, int(amount / 2))

    # get active markets for the currency
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    
    # Shortest market possible
    strategy.setMinTimeToMaturity(0, {"from": vault.governance()})
    # Funds flow through the strategy
    tx = strategy.harvest({"from":gov})
    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert next_settlement == active_markets[0][1]
    # Second shortest market possible
    actions.user_deposit(user, vault, token, int(amount / 2))
    strategy.setMinTimeToMaturity(30 * 86400, {"from": vault.governance()})
    actions.wait_until_settlement(next_settlement)
    # Funds flow to Notional
    tx2 = strategy.harvest({"from":gov})
    account = n_proxy_views.getAccount(strategy)

    amount_invested = vault.strategies(strategy)["totalDebt"]
    assert len(account["portfolio"]) == 1
    assert account["portfolio"][0][1] > next_settlement
    
    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
        account["portfolio"][0][1], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    chain.sleep(account["portfolio"][0][1] - chain.time() +1)
    chain.mine(1)
    
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    account = n_proxy_views.getAccount(strategy)
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setDoHealthCheck(False, {"from": vault.governance()})
    tx3 = strategy.harvest({"from":gov})

    assert tx3.events["Harvested"]["profit"] >= (account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS - amount_invested)
    chain.sleep(6 * 3600)
    chain.mine(1)
    
    vault.withdraw({"from": user})