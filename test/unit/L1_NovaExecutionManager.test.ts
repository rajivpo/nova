import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

import {
  checkpointBalance,
  executeRequest,
  getFactory,
  snapshotGasCost,
} from "../../utils/testUtils";
import { tuneMissingGasEstimate } from "../../tasks/tune";

import {
  L1NovaExecutionManager,
  L1NovaExecutionManager__factory,
  MockStrategy,
  MockCrossDomainMessenger,
  MockStrategy__factory,
  MockCrossDomainMessenger__factory,
  MockERC20,
  MockERC20__factory,
  NoReturnValueERC20__factory,
  BadReturnValueERC20__factory,
  ReturnFalseERC20__factory,
  MockAuthority__factory,
} from "../../typechain";

describe("L1_NovaExecutionManager", function () {
  let signers: SignerWithAddress[];
  before(async () => {
    signers = await ethers.getSigners();
  });

  let L1_NovaExecutionManager: L1NovaExecutionManager;

  /// Mocks
  let MockERC20: MockERC20;
  let MockStrategy: MockStrategy;
  let MockCrossDomainMessenger: MockCrossDomainMessenger;

  describe("constructor/setup", function () {
    it("should properly deploy mocks", async function () {
      MockERC20 = await (await getFactory<MockERC20__factory>("MockERC20")).deploy();

      MockStrategy = await (await getFactory<MockStrategy__factory>("MockStrategy")).deploy();

      MockCrossDomainMessenger = await (
        await getFactory<MockCrossDomainMessenger__factory>("MockCrossDomainMessenger")
      ).deploy();
    });

    it("should properly deploy the execution manager", async function () {
      L1_NovaExecutionManager = await (
        await getFactory<L1NovaExecutionManager__factory>("L1_NovaExecutionManager")
      ).deploy(ethers.constants.AddressZero, MockCrossDomainMessenger.address, 0);
    });

    it("should allow changing the execution manager's authority", async function () {
      const MockAuthority = await (
        await getFactory<MockAuthority__factory>("MockAuthority")
      ).deploy();

      // Set the authority to a MockAuthority that always returns true.
      await L1_NovaExecutionManager.setAuthority(MockAuthority.address);
    });

    it("should properly use constructor arguments", async function () {
      // Make sure the constructor params were properly entered.
      await L1_NovaExecutionManager.CROSS_DOMAIN_MESSENGER().should.eventually.equal(
        MockCrossDomainMessenger.address
      );
      await L1_NovaExecutionManager.L2_NOVA_REGISTRY_ADDRESS().should.eventually.equal(
        ethers.constants.AddressZero
      );
    });

    it("should contain constants that match expected values", async function () {
      // Make sure the hard revert text is correct.
      await L1_NovaExecutionManager.HARD_REVERT_TEXT().should.eventually.equal(
        "__NOVA__HARD__REVERT__"
      );
    });

    it("should allow tuning the missing gas estimate", async function () {
      const [relayer] = signers;

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        nonce: 420,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData("thisFunctionWillNotRevert"),

        // It will overestimate before tuning.
        expectedGasOverestimateAmount: 99999999999999,
      });

      await tuneMissingGasEstimate(L1_NovaExecutionManager, tx);
    });

    it("should allow updating the calldata byte gas estimate", async function () {
      const originalValue = await L1_NovaExecutionManager.calldataByteGasEstimate();

      // Test updating the calldata byte gas estimate.
      await L1_NovaExecutionManager.setCalldataByteGasEstimate(originalValue.add(1))
        .should.emit(L1_NovaExecutionManager, "CalldataByeGasEstimateUpdated")
        .withArgs(originalValue.add(1));
      await L1_NovaExecutionManager.calldataByteGasEstimate().should.eventually.equal(
        originalValue.add(1)
      );

      // Restore it to its original value.
      await L1_NovaExecutionManager.setCalldataByteGasEstimate(originalValue)
        .should.emit(L1_NovaExecutionManager, "CalldataByeGasEstimateUpdated")
        .withArgs(originalValue);
    });
  });

  describe("hardRevert", function () {
    it("should revert with the proper message", async function () {
      await L1_NovaExecutionManager.hardRevert().should.be.revertedWith(
        await L1_NovaExecutionManager.HARD_REVERT_TEXT()
      );
    });
  });

  describe("exec/execWithRecipient", function () {
    it("should revert if a hard revert is triggered", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData("thisFunctionWillHardRevert"),
      }).should.be.revertedWith("HARD_REVERT");
    });

    it("respects the deadline", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        // Set a deadline 60 seconds in the past
        deadline: Math.floor(Date.now() / 1000) - 60,
      }).should.be.revertedWith("PAST_DEADLINE");
    });

    it("should not allow specifying a null recipient", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l2Recipient: ethers.constants.AddressZero,
      }).should.be.revertedWith("NEED_RECIPIENT");
    });

    it("should not allow calling sendMessage", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockCrossDomainMessenger.address,
        l1Calldata: MockCrossDomainMessenger.interface.encodeFunctionData("sendMessage", [
          ethers.constants.AddressZero,
          "0x00",
          0,
        ]),
      }).should.be.revertedWith("UNSAFE_CALLDATA");
    });

    it("should not allow calling transferFrom", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockERC20.address,
        l1Calldata: MockERC20.interface.encodeFunctionData("transferFrom", [
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          0,
        ]),
      }).should.be.revertedWith("UNSAFE_CALLDATA");
    });

    it("should not allow self calls", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: L1_NovaExecutionManager.address,
      }).should.be.revertedWith("UNSAFE_STRATEGY");
    });

    it("should not allow reentrancy", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTryToReenterAndHardRevertIfFails"
        ),
      }).should.be.revertedWith("HARD_REVERT");
    });

    it("should properly execute a minimal exec", async function () {
      const [relayer] = signers;

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData("thisFunctionWillNotRevert"),
      });

      await snapshotGasCost(tx);
    });

    it("should properly execute a stateful exec", async function () {
      const [relayer] = signers;

      await MockStrategy.counter().should.eventually.equal(1);

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData("thisFunctionWillModifyState"),
      });

      await snapshotGasCost(tx);

      await MockStrategy.counter().should.eventually.equal(2);
    });

    it("should not revert due to a soft revert", async function () {
      const [relayer] = signers;

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData("thisFunctionWillRevert"),
        shouldSoftRevert: true,
      });

      await snapshotGasCost(tx);
    });
  });

  describe("transferFromRelayer", function () {
    it("should transfer an arbitrary token to a strategy when requested", async function () {
      const [user] = signers;

      // Approve the right amount of input tokens.
      const weiAmount = ethers.utils.parseEther("1337");
      await MockERC20.approve(L1_NovaExecutionManager.address, weiAmount);

      const [relayer] = signers;

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTransferFromRelayer",
          [MockERC20.address, weiAmount]
        ),
        expectedGasOverestimateAmount: 15000, // 15000 more than expected will be consumed due to a gas refund.
      });

      await snapshotGasCost(tx)
        // The correct amount of tokens should be transferred to the strategy.
        .should.emit(MockERC20, "Transfer")
        .withArgs(user.address, MockStrategy.address, weiAmount);

      // The strategy should get properly transferred the right amount of tokens.
      await MockERC20.balanceOf(MockStrategy.address).should.eventually.equal(weiAmount);
    });

    it("will hard revert if tokens were not approved", async function () {
      const [relayer] = signers;

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTransferFromRelayer",
          [MockERC20.address, ethers.utils.parseEther("9999999")]
        ),
      }).should.be.revertedWith("HARD_REVERT");
    });

    it("will properly handle a transferFrom with no return value", async function () {
      const [relayer] = signers;

      const NoReturnValueERC20 = await (
        await getFactory<NoReturnValueERC20__factory>("NoReturnValueERC20")
      ).deploy();

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTransferFromRelayer",
          [NoReturnValueERC20.address, 0]
        ),
      });

      await snapshotGasCost(tx);
    });

    it("will hard revert if transferFrom returns a non-bool", async function () {
      const [relayer] = signers;

      const BadReturnValueERC20 = await (
        await getFactory<BadReturnValueERC20__factory>("BadReturnValueERC20")
      ).deploy();

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTransferFromRelayer",
          [BadReturnValueERC20.address, 0]
        ),
      }).should.be.revertedWith("HARD_REVERT");
    });

    it("will hard revert if transferFrom returns false without reverting", async function () {
      const [relayer] = signers;

      const ReturnFalseERC20 = await (
        await getFactory<ReturnFalseERC20__factory>("ReturnFalseERC20")
      ).deploy();

      await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillTransferFromRelayer",
          [ReturnFalseERC20.address, 0]
        ),
      }).should.be.revertedWith("HARD_REVERT");
    });

    it("will not allow anyone to call if not executing", async function () {
      await L1_NovaExecutionManager.transferFromRelayer(
        MockERC20.address,
        0
      ).should.be.revertedWith("NOT_CURRENT_STRATEGY");
    });

    it("will not allow the previous strategy to call if not executing", async function () {
      await MockStrategy.thisFunctionWillTryToTransferFromRelayerOnAnArbitraryExecutionManager(
        L1_NovaExecutionManager.address,
        MockERC20.address,
        1
      ).should.be.revertedWith("NO_ACTIVE_EXECUTION");
    });

    it("will not allow a random contract to call during execution", async function () {
      const [relayer] = signers;

      const [calcUserIncrease] = await checkpointBalance(MockERC20, relayer.address);

      // Approve the right amount of input tokens.
      const weiAmount = ethers.utils.parseEther("420");
      await MockERC20.approve(L1_NovaExecutionManager.address, weiAmount);

      const { tx } = await executeRequest(L1_NovaExecutionManager, {
        relayer: relayer.address,
        strategy: MockStrategy.address,
        l1Calldata: MockStrategy.interface.encodeFunctionData(
          "thisFunctionWillEmulateAMaliciousExternalContractTryingToStealRelayerTokens",
          [MockERC20.address, weiAmount]
        ),
        shouldSoftRevert: true,
      });

      // The transfer attempt should fail.
      await snapshotGasCost(tx).should.not.emit(MockERC20, "Transfer");

      // Balance should not change.
      await calcUserIncrease().should.eventually.equal(0);
    });
  });
});
