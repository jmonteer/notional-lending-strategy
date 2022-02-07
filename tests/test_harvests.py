from utils import actions, checks, utils
import pytest

# tests harvesting a strategy that returns profits correctly
def test_profitable_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, currencyID, n_proxy_implementation, gov, token_whale, n_proxy_account, 
    million_in_token
):
    # Deposit to the vault

    initial_balance = token.balanceOf(vault.address)

    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)

    amount_invested = vault.creditAvailable({"from":strategy})

    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount_invested / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()
        )
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        min_market_index,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    total_assets = strategy.estimatedTotalAssets()
    
    assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
    # Add some code before harvest #2 to simulate earning yield
    actions.wait_until_settlement(next_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        1,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

    # check that estimatedTotalAssets estimates correctly
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == position_cash
    assert position_cash > amount
    profit_amount = 0
    loss_amount = 0

    before_pps = vault.pricePerShare()
    print("Vault assets 1: ", vault.totalAssets())
    # Harvest 2: Harvest with unrealized and non-mature profits: should not change anything 
    chain.sleep(1)
    
    tx = strategy.harvest({"from": strategist})
    
    checks.check_harvest_profit(tx, profit_amount, RELATIVE_APPROX)
    checks.check_harvest_loss(tx, loss_amount, RELATIVE_APPROX)

    # Update debt ratio to force liqudating positions
    vault.updateStrategyDebtRatio(strategy, 0, {"from": vault.governance()})

    # Harvest 3: Remove funds to pay the debt's vault - should remove a total of 'amount' between token and reported 
    # loss
    strategy.setToggleRealizeLosses(True, {"from":gov})

    tx2 = strategy.harvest({"from":gov})

    account = n_proxy_views.getAccount(strategy)

    assert amount_invested == (tx2.events["Harvested"]["loss"] + tx2.events["Harvested"]["debtPayment"])
    assert (tx2.events["Harvested"]["debtPayment"] + account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS) > amount
    

    # Harvest 3: wait until maturity to settle and withdraw profits
    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
        account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    chain.sleep(account[0][0] - chain.time() + 1)
    chain.mine(1)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    account = n_proxy_views.getAccount(strategy)
    
    # Do not check as we are realizing profits without debt
    strategy.setDoHealthCheck(False, {"from": gov})
    tx3 = strategy.harvest({"from":gov})
    if currencyID == 4:
        assert pytest.approx(tx3.events["Harvested"]["profit"], rel=RELATIVE_APPROX) == account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    else:
        assert tx3.events["Harvested"]["profit"] >= account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    balance = token.balanceOf(vault.address)  # Profits go to vault
    print("ETH Balance is ", vault.balance())
    print("Vault assets 2: ", vault.totalAssets())
    assert (balance - initial_balance) >= tx3.events["Harvested"]["profit"]
    assert vault.pricePerShare() > before_pps


# # tests harvesting a strategy that reports losses
def test_lossy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, balance_threshold, n_proxy_implementation, gov
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
    
    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold, min_market_index)

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)

    amount_invested = vault.creditAvailable({"from":strategy})
    
    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount_invested / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()
        )
    strategy.harvest({"from": strategist})
    
    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    actions.wait_half_until_settlement(next_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID, min_market_index)
    print("Amount: ", amount_invested)
    position_cash = strategy.estimatedTotalAssets()
    loss_amount = amount_invested - position_cash
    assert loss_amount > 0
    print("TA: ", position_cash)
    # Harvest 2: Realize loss
    chain.sleep(1)

    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setToggleRealizeLosses(True, {"from":gov})
    strategy.setDoHealthCheck(False, {"from": gov})
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_loss(tx, loss_amount, RELATIVE_APPROX)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})
    assert (amount - token.balanceOf(user)) <= loss_amount


# tests harvesting a strategy twice, once with loss and another with profit
# it checks that even with previous profit and losses, accounting works as expected
def test_choppy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold, gov, million_in_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)

    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold, min_market_index)
    # assert False
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    actions.wait_half_until_settlement(next_settlement)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID, min_market_index)

    print("TA: ", strategy.estimatedTotalAssets())

    # Harvest 2: Realize loss
    chain.sleep(1)
    position_cash = strategy.estimatedTotalAssets()

    amount_invested = vault.strategies(strategy)["totalDebt"]
    want_balance = token.balanceOf(strategy)

    vault.updateStrategyDebtRatio(strategy, int(vault.strategies(strategy)["debtRatio"]/2), {"from":vault.governance()})
    
    loss_amount = (amount_invested - position_cash) * \
        (vault.debtOutstanding({"from":strategy}) - want_balance) \
         / (vault.strategies(strategy)["totalDebt"] - want_balance)
    assert loss_amount > 0
    strategy.setToggleRealizeLosses(True, {"from":gov})
    strategy.setDoHealthCheck(False, {"from": gov})
    tx = strategy.harvest({"from": strategist})

    # Harvest 3: Realize profit on the rest of the position
    print("TA 1: ", strategy.estimatedTotalAssets())
    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user,
        account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    chain.sleep(next_settlement - chain.time() - 100)
    chain.mine(1)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    print("TA 2: ", strategy.estimatedTotalAssets())
    position_cash = strategy.estimatedTotalAssets()
    profit_amount = position_cash - vault.strategies(strategy)["totalDebt"]
    assert profit_amount > 0
    
    realized_profit = 0
    tx = strategy.harvest({"from": strategist})
    
    checks.check_harvest_profit(tx, realized_profit, RELATIVE_APPROX)

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert pytest.approx(vault.strategies(strategy)["totalLoss"], rel=RELATIVE_APPROX) == loss_amount
    assert pytest.approx(vault.strategies(strategy)["totalGain"], rel=RELATIVE_APPROX) == realized_profit

    vault.withdraw({"from": user})

def test_maturity_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold, million_in_token
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    min_market_index = utils.get_min_market_index(strategy, currencyID, n_proxy_views)
        
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    

    amount_invested = vault.creditAvailable({"from":strategy})

    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount_invested / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        min_market_index,
        chain.time()
        )
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        min_market_index,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    total_assets = strategy.estimatedTotalAssets()
    
    assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
    # Add some code before harvest #2 to simulate earning yield
    actions.wait_until_settlement(next_settlement)

    harvest_trigger = strategy.harvestTrigger(0)
    assert harvest_trigger == False

    actions.initialize_intermediary_markets(n_proxy_views, currencyID, n_proxy_implementation, user, 
        account[0][0], n_proxy_batch, token, token_whale, n_proxy_account, million_in_token)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)
    chain.sleep(next_settlement - chain.time() + 1)
    chain.mine(1)
    checks.check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user)

    harvest_trigger = strategy.harvestTrigger(0)
    assert harvest_trigger == True
    
    totalAssets = strategy.estimatedTotalAssets()
    position_cash = account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

    assert pytest.approx(position_cash+token.balanceOf(strategy), rel=RELATIVE_APPROX) == totalAssets
    profit_amount = totalAssets - amount_invested
    assert profit_amount > 0
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    strategy.setDoHealthCheck(False, {"from": vault.governance()})
    tx = strategy.harvest({"from": strategist})
    assert tx.events["Harvested"]["profit"] >= profit_amount

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert vault.strategies(strategy)["totalLoss"] == 0
    assert vault.strategies(strategy)["totalGain"] >= profit_amount
    
    vault.withdraw({"from": user})

    