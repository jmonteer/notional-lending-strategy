import brownie
from brownie import interface
import pytest

# This file is reserved for standard checks
def check_vault_empty(vault):
    assert vault.totalAssets() == 0
    assert vault.totalSupply() == 0


def check_strategy_empty(strategy):
    assert strategy.estimatedTotalAssets() == 0
    vault = interface.VaultAPI(strategy.vault())
    assert vault.strategies(strategy).dict()["totalDebt"] == 0


def check_revoked_strategy(vault, strategy):
    status = vault.strategies(strategy).dict()
    assert status.debtRatio == 0
    assert status.totalDebt == 0
    return


def check_harvest_profit(tx, profit_amount, RELATIVE_APPROX):
    assert pytest.approx(tx.events["Harvested"]["profit"], rel=RELATIVE_APPROX) == profit_amount


def check_harvest_loss(tx, loss_amount, RELATIVE_APPROX):
    assert pytest.approx(tx.events["Harvested"]["loss"], rel=RELATIVE_APPROX) == loss_amount


def check_accounting(vault, strategy, totalGain, totalLoss, totalDebt):
    # inputs have to be manually calculated then checked
    status = vault.strategies(strategy).dict()
    assert status["totalGain"] == totalGain
    assert status["totalLoss"] == totalLoss
    assert status["totalDebt"] == totalDebt
    return

def check_active_markets(n_proxy_views, currencyID, n_proxy_implementation, user):
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    if active_markets[0][2] == 0:
        n_proxy_implementation.initializeMarkets(currencyID, 0, {"from": user})
