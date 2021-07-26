import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import { jestSnapshotPlugin } from "mocha-chai-jest-snapshot";
chai.use(jestSnapshotPlugin());
chai.use(chaiAsPromised);
chai.should();

import { ethers } from "hardhat";
import { BigNumberish, Contract, ContractReceipt, ContractTransaction } from "ethers";

import chalk from "chalk";
import { IERC20 } from "../../typechain";
import { Interface } from "ethers/lib/utils";

/** Returns an array of function fragments that are stateful from an interface. */
export function getAllStatefulFragments(contractInterface: Interface) {
  return Object.values(contractInterface.functions).filter((f) => !f.constant);
}

/** Gets an ethers factory for a contract. T should be the typechain factory type of the contract (ie: MockERC20__factory). */
export function getFactory<T>(name: string): Promise<T> {
  return ethers.getContractFactory(name) as any;
}

export function getOVMFactory<T>(name: string, l2: boolean, path?: string): T {
  const artifact = require(`../../artifacts${l2 ? "-ovm" : ""}/contracts/${
    path ?? ""
  }${name}.sol/${name}.json`);

  return new ethers.ContractFactory(artifact.abi, artifact.bytecode) as any;
}

/** Increases EVM time by `seconds` and mines a new block. */
export async function increaseTimeAndMine(seconds: BigNumberish) {
  await ethers.provider.send("evm_increaseTime", [parseInt(seconds.toString())]);
  await ethers.provider.send("evm_mine", []);
}

/**
 *  Records the gas usage of a transaction, and checks against the most recent saved Jest snapshot.
 * If not in CI mode it won't stop tests (just show a console log).
 * To update the Jest snapshot run `npm run gas-changed`
 */
export async function snapshotGasCost(x: Promise<ContractTransaction>) {
  // Only check gas estimates if we're not in coverage mode, as gas estimates are messed up in coverage mode.
  if (!process.env.HARDHAT_COVERAGE_MODE_ENABLED) {
    let receipt: ContractReceipt = await (await x).wait();
    try {
      receipt.gasUsed.toNumber().should.toMatchSnapshot();
    } catch (e) {
      console.log(
        chalk.red(
          "(CHANGE) " +
            e.message
              .replace("expected", "used")
              .replace("to equal", "gas, but the snapshot expected it to use") +
            " gas"
        )
      );

      if (process.env.CI) {
        return Promise.reject("reverted: Gas consumption changed from expected.");
      }
    }
  }

  return x;
}

/**
 * Checkpoints `user`'s ether `token` balance upon calling.
 * Returns two functions (calcIncrease and calcDecrease,
 * calling calcIncrease will return the  `user`'s new `token`
 * balance minus the starting balance. Calling calcDecrease
 * subtracts the final balance from the balance.
 * */
export async function checkpointBalance(token: IERC20, user: string) {
  const startingBalance = await token.balanceOf(user);

  async function calcIncrease() {
    const finalBalance = await token.balanceOf(user);

    return finalBalance.sub(startingBalance);
  }

  async function calcDecrease() {
    const finalBalance = await token.balanceOf(user);

    return startingBalance.sub(finalBalance);
  }

  return [calcIncrease, calcDecrease];
}

export function createLocalProvider(port: number) {
  return new ethers.providers.JsonRpcProvider("http://127.0.0.1:" + port);
}

export * from "./nova";
