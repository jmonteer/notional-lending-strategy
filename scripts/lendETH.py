from pathlib import Path

from brownie import Strategy, accounts, config, network, project, web3, Contract
from eth_utils import is_checksum_address
import click

def main():
    nProxy = Contract.from_explorer("0x1344A36A1B56144C3Bc62E7757377D288fDE0369")
    # print(nProxy.selectors)
    actionContract = Contract.from_explorer(nProxy.BATCH_ACTION())
    nProxy_batch = Contract.from_abi("BATCH", nProxy.address, actionContract.abi)
    # print(actionContract.selectors)
    accountContract = Contract.from_explorer(nProxy.ACCOUNT_ACTION())
    nProxy_account = Contract.from_abi("ACCOUNT", nProxy.address, accountContract.abi)
    # print(accountContract.selectors)
    viewsContract = Contract(nProxy.VIEWS())
    nProxy_views = Contract.from_abi("VIEWS", nProxy.address, viewsContract.abi)
    # print(viewsContract.selectors)

    # DAI_token_address = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    # cDAI_token_address = "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643"
    # DAI_currency_Id = nProxy_views.getCurrencyId(cDAI_token_address)
    # print("DAI currency Id is %d" % (DAI_currency_Id))

    ETH_token_address = "0x0"
    cETH_token_address = '0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5'
    ETH_currency_Id = nProxy_views.getCurrencyId(cETH_token_address)
    print("ETH currency Id is %d" % (ETH_currency_Id))

    gov = accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)
    yVault = Contract("0xa258C4606Ca8206D8aA700cE2143D7db854D168c")

    strategy = Strategy.deploy(yVault.address, nProxy.address, {"from": gov})

    tx = yVault.addStrategy(strategy.address, 10, 0, 1000000000000000000, 0, {"from":gov})

    tx = strategy.harvest()
    # bal = strategy.balanceOfWant()
    # print("Balance is : {%d}" % bal)

    # nProxy_batch.batchBalanceAndTradeAction("0x12B1b1d8fF0896303E2C4d319087F5f14A537395", \
    #     [(2,1,999999990000000000,0,1,1,\
    #         [0x00020000000000000005fbf64400d5992c000000000000000000000000000000])], \
    #             {"from": "0x12B1b1d8fF0896303E2C4d319087F5f14A537395",\
    #                  "value":999999990000000000})



    assert False
