from pathlib import Path
from textwrap import shorten

from brownie import Strategy, accounts, config, network, project, web3, Contract, chain
from eth_utils import is_checksum_address
import click

API_VERSION = config["dependencies"][0].split("@")[-1]
Vault = project.load(
    Path.home() / ".brownie" / "packages" / config["dependencies"][0]
).Vault

def amount_to_want(amount, token):
    token_prices = {
    "WBTC": 35_000,
    "WETH": 2_000,
    "LINK": 20,
    "YFI": 30_000,
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
    }
    return round(amount / token_prices[token.symbol()]) * 10 ** token.decimals()

def free_up_vault(vault):
    strat_to_close = Contract("0x0c8f62939Aeee6376f5FAc88f48a5A3F2Cf5dEbB")
    vault.updateStrategyDebtRatio(strat_to_close, 0, {"from":vault.governance()})
    strat_to_close.harvest({"from":vault.governance()})

def free_up_vault_DAI(vault):
    strat_to_close = Contract("0xa6D1C610B3000F143c18c75D84BaA0eC22681185")
    strat_to_close.setDoHealthCheck(False, {"from":vault.governance()})
    vault.updateStrategyDebtRatio(strat_to_close, 0, {"from":vault.governance()})
    strat_to_close.harvest({"from":vault.governance()})

def print_market_IR(currencyID, n_proxy_views):
    active_markets = n_proxy_views.getActiveMarkets(currencyID)
    shortest_maturity = active_markets[0]
    latest_rate = shortest_maturity[5] / 1e7
    oracle_rate = shortest_maturity[6] / 1e7
    print("Last market rate: ",latest_rate,"%, oracle rate: ", oracle_rate, "%")

def main():
    print("########### Notional Fixed term lending live deployment test ###########")
    
    print("Setup contracts")
    strategist = accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)
    vault = Contract("0xa354F35829Ae975e850e23e9615b11Da1B3dC4DE")
    vault_DAI = Contract("0xdA816459F1AB5631232FE5e97a05BBBb94970c95")
    gov = vault.governance()
    gov_DAI = vault_DAI.governance()
    notional_proxy = "0x1344A36A1B56144C3Bc62E7757377D288fDE0369"
    n_proxy = Contract.from_explorer(notional_proxy)
    views_contract = Contract(n_proxy.VIEWS())
    n_proxy_views = Contract.from_abi("VIEWS", n_proxy.address, views_contract.abi)
    currencyID = 3 # USDC
    token = Contract("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")  # USDC
    min_amount_harvest = amount_to_want(50_000, token)
    # initial_strategy = strategist.deploy(Strategy, vault, notional_proxy, currencyID, min_amount_harvest)
    initial_strategy = Contract("0x0EeeBD67CfaE6a9E78433B301fc44C13Ba205bf6")

    print("#### Cloning strat for USDC ####")
    # strategy_address = initial_strategy.cloneStrategy(
    #     vault,
    #     strategist,
    #     strategist,
    #     strategist,
    #     notional_proxy,
    #     currencyID,
    #     min_amount_harvest,
    #     {"from": vault.governance()}
    # ).return_value
    # strategy = Strategy.at(strategy_address)
    strategy = Contract("0x9D42427830e617C7cf55050092E899569CeE0233")

    print("#### Cloning strat for DAI ####")
    currencyID_DAI = 2
    token_DAI = Contract("0x6B175474E89094C44Da98b954EedeAC495271d0F")  # DAI
    min_amount_harvest = amount_to_want(50_000, token_DAI)
    
    # strategy_address_DAI = strategy.cloneStrategy(
    #     vault_DAI,
    #     strategist,
    #     strategist,
    #     strategist,
    #     notional_proxy,
    #     currencyID_DAI,
    #     min_amount_harvest,
    #     {"from": vault.governance()}
    # ).return_value
    # strategy_DAI = Strategy.at(strategy_address_DAI)
    strategy_DAI = Contract("0x091ceD53A84dad18486Afc4d05F313116AEbEf74")

    free_up_vault(vault)
    free_up_vault_DAI(vault_DAI)

    print("### ONE MILLION HARVEST ###")
    one_million_usdc = amount_to_want(1_000_000, token)
    vault.addStrategy(strategy, 1_000, 0, one_million_usdc, 1000, {"from": gov})

    one_million_dai = amount_to_want(1_000_000, token_DAI)
    vault_DAI.addStrategy(strategy_DAI, 1_000, 0, one_million_dai, 1000, {"from": gov_DAI})

    print("USDC Market IR before entering: ")
    print_market_IR(currencyID, n_proxy_views)
    tx = strategy.harvest({"from":gov})
    print("USDC Market IR after entering: ")
    print_market_IR(currencyID, n_proxy_views)

    print("DAI Market IR before entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("DAI Market IR after entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    
    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())
    chain.mine(1, timedelta=7*86_400)
    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault_DAI.updateStrategyDebtRatio(strategy_DAI, 0, {"from": gov_DAI})
    strategy.setToggleRealizeProfits(True, {"from":gov})
    strategy_DAI.setToggleRealizeProfits(True, {"from":gov_DAI})
    
    print("USDC Market IR before exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    tx = strategy.harvest({"from":gov})
    print("USDC Market IR after exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    print("USDC Profit after 1 week with 1 million is: ", tx.events["Harvested"]["profit"] / 10**token.decimals())

    print("DAI Market IR before exiting: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("DAI Market IR after exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    print("DAI Profit after 1 week with 1 million is: ", tx_DAI.events["Harvested"]["profit"] / 10**token_DAI.decimals())

    print("### FIVE MILLION HARVEST ###")
    vault.updateStrategyDebtRatio(strategy, 1_000, {"from": gov})
    vault_DAI.updateStrategyDebtRatio(strategy_DAI, 1_000, {"from": gov_DAI})
    vault.updateStrategyMaxDebtPerHarvest(strategy, one_million_usdc * 5, {"from": gov})
    vault_DAI.updateStrategyMaxDebtPerHarvest(strategy_DAI, one_million_dai * 5, {"from": gov_DAI})
    
    print("Market IR before entering: ")
    print_market_IR(currencyID, n_proxy_views)
    tx = strategy.harvest({"from":gov})
    print("Market IR after entering: ")
    print_market_IR(currencyID, n_proxy_views)

    print("DAI Market IR before entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("DAI Market IR after entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    
    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())
    chain.mine(1, timedelta=7*86_400)
    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault_DAI.updateStrategyDebtRatio(strategy_DAI, 0, {"from": gov_DAI})
    strategy.setToggleRealizeProfits(True, {"from":gov})
    strategy_DAI.setToggleRealizeProfits(True, {"from":gov_DAI})

    print("USDC Market IR before exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    tx = strategy.harvest({"from":gov})
    print("USDC Market IR after exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    print("USDC Profit after 1 week with 5 million is: ", tx.events["Harvested"]["profit"] / 10**token.decimals())

    print("DAI Market IR before exiting: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("DAI Market IR after exiting: ")
    print_market_IR(currencyID, n_proxy_views)
    print("DAI Profit after 1 week with 5 million is: ", tx_DAI.events["Harvested"]["profit"] / 10**token_DAI.decimals())

    print("### FIFTEEN MILLION HARVEST ###")
    vault.updateStrategyDebtRatio(strategy, 1_000, {"from": gov})
    vault_DAI.updateStrategyDebtRatio(strategy_DAI, 1_000, {"from": gov_DAI})
    vault.updateStrategyMaxDebtPerHarvest(strategy, one_million_usdc * 15, {"from": gov})
    vault_DAI.updateStrategyMaxDebtPerHarvest(strategy_DAI, one_million_dai * 15, {"from": gov_DAI})

    print("Market IR before entering: ")
    print_market_IR(currencyID, n_proxy_views)
    tx = strategy.harvest({"from":gov})
    print("Market IR after entering: ")
    print_market_IR(currencyID, n_proxy_views)

    print("DAI Market IR before entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("DAI Market IR after entering: ")
    print_market_IR(currencyID_DAI, n_proxy_views)

    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())
    chain.mine(1, timedelta=7*86_400)
    print("USDC Strategy estimated assets: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets: ", strategy_DAI.estimatedTotalAssets())
    print("Profit after 1 week with 15 million USDC is: ", (strategy.estimatedTotalAssets() - one_million_usdc * 15) / 10**token.decimals())
    print("Profit after 1 week with 15 million DAI is: ", (strategy_DAI.estimatedTotalAssets() - one_million_dai * 15) / 10**token_DAI.decimals())

    chain.mine(1, timestamp=1648512000)
    print("USDC Strategy estimated assets at maturity: ", strategy.estimatedTotalAssets())
    print("DAI Strategy estimated assets at maturity: ", strategy_DAI.estimatedTotalAssets())

    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    vault_DAI.updateStrategyDebtRatio(strategy_DAI, 0, {"from": gov_DAI})
    tx = strategy.harvest({"from":gov})
    tx_DAI = strategy_DAI.harvest({"from":gov_DAI})
    print("USDC Profit after maturity with 15 million is: ", tx.events["Harvested"]["profit"] / 10**token.decimals())
    print("DAI Profit after maturity with 15 million is: ", tx_DAI.events["Harvested"]["profit"] / 10**token_DAI.decimals())
    print("USDC Final strategy situation with vault at maturity: ")
    print(vault.strategies(strategy).dict())
    print("DAI Final strategy situation with vault at maturity: ")
    print(vault_DAI.strategies(strategy_DAI).dict())

    print("USDC All these tests report at maturity: ", vault.strategies(strategy).dict()["totalGain"] / 10**token.decimals())
    print("DAI All these tests report at maturity: ", vault_DAI.strategies(strategy_DAI).dict()["totalGain"] / 10**token_DAI.decimals())

    assert 0

