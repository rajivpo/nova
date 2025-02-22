// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.7.6;
pragma abicoder v2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import {Auth} from "@rari-capital/solmate/src/auth/Auth.sol";
import {ReentrancyGuard} from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";

import {NovaExecHashLib} from "./libraries/NovaExecHashLib.sol";
import {CrossDomainEnabled, iOVM_CrossDomainMessenger} from "./external/CrossDomainEnabled.sol";

contract L2_NovaRegistry is Auth, CrossDomainEnabled, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /*///////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice If an execution on L1 soft reverts, the reward recipient
    /// will only receive the tip divided by the PENALTY_TIP_DIVISOR. The
    /// the remaining portion will be refunded to the creator of the request.
    uint256 public constant PENALTY_TIP_DIVISOR = 2;

    /// @notice The maximum amount of input tokens that may be added to a request.
    uint256 public constant MAX_INPUT_TOKENS = 5;

    /// @notice The minimum delay between when `unlockTokens` and `withdrawTokens` can be called.
    uint256 public constant MIN_UNLOCK_DELAY_SECONDS = 300;

    /// @notice The ERC20 ETH users must use to pay for the L1 gas usage of request.
    IERC20 public immutable ETH;

    /// @param _ETH The ERC20 ETH users must use to pay for the L1 gas usage of request.
    /// @param _xDomainMessenger The L2 xDomainMessenger contract to trust for receiving messages.
    constructor(address _ETH, iOVM_CrossDomainMessenger _xDomainMessenger) CrossDomainEnabled(_xDomainMessenger) {
        ETH = IERC20(_ETH);
    }

    /*///////////////////////////////////////////////////////////////
                    EXECUTION MANAGER ADDRESS STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the only contract authorized to make cross domain calls to `execCompleted`.
    address public L1_NovaExecutionManagerAddress;

    /// @notice Authorizes the `_L1_NovaExecutionManagerAddress` to make cross domain calls to `execCompleted`.
    /// @notice Each call to `connectExecutionManager` overrides the previous value, you cannot have multiple authorized execution managers at once.
    /// @param _L1_NovaExecutionManagerAddress The address to be authorized to make cross domain calls to `execCompleted`.
    function connectExecutionManager(address _L1_NovaExecutionManagerAddress) external requiresAuth {
        L1_NovaExecutionManagerAddress = _L1_NovaExecutionManagerAddress;

        emit ConnectExecutionManager(_L1_NovaExecutionManagerAddress);
    }

    /*///////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when `connectExecutionManager` is called.
    event ConnectExecutionManager(address _L1_NovaExecutionManagerAddress);

    /// @notice Emitted when `requestExec` is called.
    /// @param execHash The unique identifier generated for this request.
    /// @param strategy The address of the "strategy" contract on L1 a relayer should call with `calldata`.
    event RequestExec(bytes32 indexed execHash, address indexed strategy);

    /// @notice Emitted when `execCompleted` is called.
    /// @param execHash The unique identifier associated with the request executed.
    /// @param rewardRecipient The address the relayer specified to be the recipient of the tokens on L2.
    /// @param reverted If the strategy reverted on L1 during execution.
    /// @param gasUsed The amount of gas used by the execution tx on L1.
    event ExecCompleted(bytes32 indexed execHash, address indexed rewardRecipient, bool reverted, uint256 gasUsed);

    /// @notice Emitted when `claimInputTokens` is called.
    /// @param execHash The unique identifier associated with the request that had its input tokens claimed.
    event ClaimInputTokens(bytes32 indexed execHash);

    /// @notice Emitted when `withdrawTokens` is called.
    /// @param execHash The unique identifier associated with the request that had its tokens withdrawn.
    event WithdrawTokens(bytes32 indexed execHash);

    /// @notice Emitted when `unlockTokens` is called.
    /// @param execHash The unique identifier associated with the request that had a token unlock scheduled.
    /// @param unlockTimestamp When the unlock will set into effect and the creator will be able to call `withdrawTokens`.
    event UnlockTokens(bytes32 indexed execHash, uint256 unlockTimestamp);

    /// @notice Emitted when `relockTokens` is called.
    /// @param execHash The unique identifier associated with the request that had its tokens relocked.
    event RelockTokens(bytes32 indexed execHash);

    /// @notice Emitted when `speedUpRequest` is called.
    /// @param execHash The unique identifier associated with the request that was uncled and replaced by the newExecHash.
    /// @param newExecHash The execHash of the resubmitted request (copy of its uncle with an updated gasPrice).
    /// @param newNonce The nonce of the resubmitted request.
    /// @param switchTimestamp When the uncled request (`execHash`) will have its tokens transferred to the resubmitted request (`newExecHash`).
    event SpeedUpRequest(
        bytes32 indexed execHash,
        bytes32 indexed newExecHash,
        uint256 newNonce,
        uint256 switchTimestamp
    );

    /*///////////////////////////////////////////////////////////////
                       GLOBAL NONCE COUNTER STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The most recent nonce assigned to an execution request.
    uint256 public systemNonce;

    /*///////////////////////////////////////////////////////////////
                           PER REQUEST STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps execHashes to the creator of each request.
    mapping(bytes32 => address) public getRequestCreator;
    /// @notice Maps execHashes to the address of the strategy associated with the request.
    mapping(bytes32 => address) public getRequestStrategy;
    /// @notice Maps execHashes to the calldata associated with the request.
    mapping(bytes32 => bytes) public getRequestCalldata;
    /// @notice Maps execHashes to the gas limit a relayer should use to execute the request.
    mapping(bytes32 => uint256) public getRequestGasLimit;
    /// @notice Maps execHashes to the gas price a relayer must use to execute the request.
    mapping(bytes32 => uint256) public getRequestGasPrice;
    /// @notice Maps execHashes to the additional tip in wei relayers will receive for executing them.
    mapping(bytes32 => uint256) public getRequestTip;
    /// @notice Maps execHashes to the nonce of each request.
    /// @notice This is just for convenience, does not need to be on-chain.
    mapping(bytes32 => uint256) public getRequestNonce;

    /// @notice A token/amount pair that a relayer will need on L1 to execute the request (and will be returned to them on L2).
    /// @param l2Token The token on L2 to transfer to the relayer upon a successful execution.
    /// @param amount The amount of the `l2Token` to the relayer upon a successful execution (scaled by the `l2Token`'s decimals).
    /// @dev Relayers may have to reference a registry/list of some sort to determine the equivalent L1 token they will need.
    /// @dev The decimal scheme may not align between the L1 and L2 tokens, a relayer should check via off-chain logic.
    struct InputToken {
        IERC20 l2Token;
        uint256 amount;
    }

    /// @notice Maps execHashes to the input tokens a relayer must have to execute the request.
    mapping(bytes32 => InputToken[]) public requestInputTokens;

    function getRequestInputTokens(bytes32 execHash) external view returns (InputToken[] memory) {
        return requestInputTokens[execHash];
    }

    /*///////////////////////////////////////////////////////////////
                       INPUT TOKEN RECIPIENT STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct containing data about the status of the request's input tokens.
    /// @param recipient The user who is entitled to take the request's input tokens.
    /// If recipient is not address(0), this means the request is no longer executable.
    /// @param isClaimed Will be true if the input tokens have been removed, false if not.
    struct InputTokenRecipientData {
        address recipient;
        bool isClaimed;
    }

    /// @notice Maps execHashes to a struct which contains data about the status of the request's input tokens.
    mapping(bytes32 => InputTokenRecipientData) public getRequestInputTokenRecipientData;

    /*///////////////////////////////////////////////////////////////
                              UNLOCK STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps execHashes to a timestamp representing when the request will have its tokens unlocked, meaning the creator can withdraw their bounties/inputs.
    /// @notice Will be 0 if no unlock has been scheduled.
    mapping(bytes32 => uint256) public getRequestUnlockTimestamp;

    /*///////////////////////////////////////////////////////////////
                              UNCLE STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps execHashes which represent resubmitted requests (via speedUpRequest) to their corresponding "uncled" request's execHash.
    /// @notice An uncled request is a request that has had its tokens removed via `speedUpRequest` in favor of a resubmitted request generated in the transaction.
    /// @notice Will be bytes32("") if `speedUpRequest` has not been called with the `execHash`.
    mapping(bytes32 => bytes32) public getRequestUncle;

    /// @notice Maps execHashes to a timestamp representing when the request will be disabled and replaced by a re-submitted request with a higher gas price (via `speedUpRequest`).
    /// @notice Will be 0 if `speedUpRequest` has not been called with the `execHash`.
    mapping(bytes32 => uint256) public getRequestDeathTimestamp;

    /*///////////////////////////////////////////////////////////////
                           STATEFUL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Request `strategy` to be executed with `l1Calldata`.
    /// @notice The caller must approve `(gasPrice * gasLimit) + tip` of `ETH` before calling.
    /// @param strategy The address of the "strategy" contract on L1 a relayer should call with `calldata`.
    /// @param l1Calldata The abi encoded calldata a relayer should call the `strategy` with on L1.
    /// @param gasLimit The gas limit a relayer should use on L1.
    /// @param gasPrice The gas price (in wei) a relayer should use on L1.
    /// @param tip The additional wei to pay as a tip for any relayer that executes this request.
    /// @param inputTokens An array of MAX_INPUT_TOKENS or less token/amount pairs that a relayer will need on L1 to execute the request (and will be returned to them on L2).
    /// @return execHash The "execHash" (unique identifier) for this request.
    function requestExec(
        address strategy,
        bytes calldata l1Calldata,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 tip,
        InputToken[] calldata inputTokens
    ) public nonReentrant requiresAuth returns (bytes32 execHash) {
        // Do not allow more than MAX_INPUT_TOKENS input tokens.
        require(inputTokens.length <= MAX_INPUT_TOKENS, "TOO_MANY_INPUTS");

        // Increment global nonce.
        systemNonce += 1;
        // Compute execHash for this request.
        execHash = NovaExecHashLib.compute({
            nonce: systemNonce,
            strategy: strategy,
            l1Calldata: l1Calldata,
            gasPrice: gasPrice
        });

        // Store all critical request data.
        getRequestCreator[execHash] = msg.sender;
        getRequestStrategy[execHash] = strategy;
        getRequestCalldata[execHash] = l1Calldata;
        getRequestGasLimit[execHash] = gasLimit;
        getRequestGasPrice[execHash] = gasPrice;
        getRequestTip[execHash] = tip;
        // Storing the nonce is just for convenience; it does not need to be on-chain.
        getRequestNonce[execHash] = systemNonce;

        emit RequestExec(execHash, strategy);

        // Transfer in ETH to pay for max gas usage + tip.
        ETH.safeTransferFrom(msg.sender, address(this), gasLimit.mul(gasPrice).add(tip));

        // Transfer input tokens in that msg.sender has approved.
        for (uint256 i = 0; i < inputTokens.length; i++) {
            inputTokens[i].l2Token.safeTransferFrom(msg.sender, address(this), inputTokens[i].amount);

            // Copy over this index to the requestInputTokens mapping (we can't just put a calldata/memory array directly into storage so we have to go index by index).
            requestInputTokens[execHash].push(inputTokens[i]);
        }
    }

    /// @notice Calls `requestExec` with all relevant parameters along with calling `unlockTokens` with the `autoUnlockDelay` argument.
    /// @dev See `requestExec` and `unlockTokens` for more information.
    function requestExecWithTimeout(
        address strategy,
        bytes calldata l1Calldata,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 tip,
        InputToken[] calldata inputTokens,
        uint256 autoUnlockDelaySeconds
    ) external returns (bytes32 execHash) {
        // Create a request and get its execHash.
        execHash = requestExec(strategy, l1Calldata, gasLimit, gasPrice, tip, inputTokens);

        // Schedule an unlock set to complete autoUnlockDelay seconds from now.
        unlockTokens(execHash, autoUnlockDelaySeconds);
    }

    /// @notice Claims input tokens earned from executing a request.
    /// @notice Request creators must also call this function if their request reverted (as input tokens are not sent to relayers if the request reverts).
    /// @notice Anyone may call this function, but the tokens will be sent to the proper input token recipient
    /// (either the l2Recipient given in `execCompleted` or the request creator if the request reverted).
    /// @param execHash The hash of the executed request.
    function claimInputTokens(bytes32 execHash) external nonReentrant requiresAuth {
        // Get a pointer to the input token recipient data.
        InputTokenRecipientData storage inputTokenRecipientData = getRequestInputTokenRecipientData[execHash];

        // Ensure input tokens for this request are ready to be sent to a recipient.
        require(inputTokenRecipientData.recipient != address(0), "NO_RECIPIENT");
        // Ensure that the tokens have not already been claimed.
        require(!inputTokenRecipientData.isClaimed, "ALREADY_CLAIMED");

        // Mark the input tokens as claimed.
        inputTokenRecipientData.isClaimed = true;

        emit ClaimInputTokens(execHash);

        // Loop over each input token to transfer it to the recipient.
        InputToken[] memory inputTokens = requestInputTokens[execHash];
        for (uint256 i = 0; i < inputTokens.length; i++) {
            inputTokens[i].l2Token.safeTransfer(inputTokenRecipientData.recipient, inputTokens[i].amount);
        }
    }

    /// @notice Unlocks a request's tokens with a delay. Once the delay has passed, anyone may call `withdrawTokens` on behalf of the creator to send the bounties/input tokens back.
    /// @notice msg.sender must be the creator of the request associated with the `execHash`.
    /// @param execHash The unique hash of the request to unlock.
    /// @param unlockDelaySeconds The delay in seconds until the creator can withdraw their tokens. Must be greater than or equal to `MIN_UNLOCK_DELAY_SECONDS`.
    function unlockTokens(bytes32 execHash, uint256 unlockDelaySeconds) public requiresAuth {
        // Ensure the request has not already had its tokens removed.
        (bool tokensRemoved, ) = areTokensRemoved(execHash);
        require(!tokensRemoved, "TOKENS_REMOVED");
        // Make sure that an unlock is not already scheduled.
        require(getRequestUnlockTimestamp[execHash] == 0, "UNLOCK_ALREADY_SCHEDULED");
        // Make sure the caller is the creator of the request.
        require(getRequestCreator[execHash] == msg.sender, "NOT_CREATOR");
        // Make sure the delay is greater than the minimum.
        require(unlockDelaySeconds >= MIN_UNLOCK_DELAY_SECONDS, "DELAY_TOO_SMALL");

        // Set the unlock timestamp to: block.timestamp + unlockDelaySeconds.
        uint256 unlockTimestamp = block.timestamp.add(unlockDelaySeconds);
        getRequestUnlockTimestamp[execHash] = unlockTimestamp;

        emit UnlockTokens(execHash, unlockTimestamp);
    }

    /// @notice Cancels a scheduled unlock.
    /// @param execHash The unique hash of the request which has an unlock scheduled.
    function relockTokens(bytes32 execHash) external requiresAuth {
        // Ensure the request has not already had its tokens removed.
        (bool tokensRemoved, ) = areTokensRemoved(execHash);
        require(!tokensRemoved, "TOKENS_REMOVED");
        // Make sure the caller is the creator of the request.
        require(getRequestCreator[execHash] == msg.sender, "NOT_CREATOR");
        // Ensure the request is scheduled to unlock.
        require(getRequestUnlockTimestamp[execHash] != 0, "NO_UNLOCK_SCHEDULED");

        // Reset the unlock timestamp to 0.
        delete getRequestUnlockTimestamp[execHash];

        emit RelockTokens(execHash);
    }

    /// @notice Withdraws tokens (input/gas/bounties) from an unlocked request.
    /// @notice The creator of the request associated with `execHash` must call `unlockTokens` and wait the `unlockDelaySeconds` they specified before calling `withdrawTokens`.
    /// @notice Anyone may call this function, but the tokens will still go the creator of the request associated with the `execHash`.
    /// @param execHash The unique hash of the request to withdraw from.
    function withdrawTokens(bytes32 execHash) external nonReentrant requiresAuth {
        // Ensure that the tokens are unlocked.
        (bool tokensUnlocked, ) = areTokensUnlocked(execHash);
        require(tokensUnlocked, "NOT_UNLOCKED");
        // Ensure that the tokens have not already been removed.
        (bool tokensRemoved, ) = areTokensRemoved(execHash);
        require(!tokensRemoved, "TOKENS_REMOVED");

        // Get the request creator.
        address creator = getRequestCreator[execHash];

        // Store that the request has had its input tokens removed.
        getRequestInputTokenRecipientData[execHash] = InputTokenRecipientData(creator, true);

        emit WithdrawTokens(execHash);

        // Transfer the ETH which would have been used for (gas + tip) back to the creator.
        ETH.safeTransfer(
            creator,
            getRequestGasPrice[execHash].mul(getRequestGasLimit[execHash]).add(getRequestTip[execHash])
        );

        // Transfer input tokens back to the creator.
        InputToken[] memory inputTokens = requestInputTokens[execHash];
        for (uint256 i = 0; i < inputTokens.length; i++) {
            inputTokens[i].l2Token.safeTransfer(creator, inputTokens[i].amount);
        }
    }

    /// @notice Resubmit a request with a higher gas price.
    /// @notice This will "uncle" the `execHash` which means after `MIN_UNLOCK_DELAY_SECONDS` it will be disabled and the `newExecHash` will be enabled.
    /// @notice msg.sender must be the creator of the request associated with the `execHash`.
    /// @param execHash The execHash of the request you wish to resubmit with a higher gas price.
    /// @param gasPrice The updated gas price to use for the resubmitted request.
    /// @return newExecHash The unique identifier for the resubmitted request.
    function speedUpRequest(bytes32 execHash, uint256 gasPrice) external requiresAuth returns (bytes32 newExecHash) {
        // Ensure that msg.sender is the creator of the request.
        require(getRequestCreator[execHash] == msg.sender, "NOT_CREATOR");
        // Ensure tokens have not already had its tokens removed.
        (bool tokensRemoved, ) = areTokensRemoved(execHash);
        require(!tokensRemoved, "TOKENS_REMOVED");
        // Ensure the request has not already been sped up.
        require(getRequestDeathTimestamp[execHash] == 0, "ALREADY_SPED_UP");

        // Get the previous gas price.
        uint256 previousGasPrice = getRequestGasPrice[execHash];

        // Ensure that the new gas price is greater than the previous.
        require(gasPrice > previousGasPrice, "LESS_THAN_PREVIOUS_GAS_PRICE");

        // Get the timestamp when the `execHash` would become uncled if this `speedUpRequest` call succeeds.
        uint256 switchTimestamp = MIN_UNLOCK_DELAY_SECONDS.add(block.timestamp);

        // Ensure that if there is a token unlock scheduled it would be after the switch.
        // Tokens cannot be withdrawn after the switch which is why it's safe if they unlock after.
        uint256 tokenUnlockTimestamp = getRequestUnlockTimestamp[execHash];
        require(tokenUnlockTimestamp == 0 || tokenUnlockTimestamp > switchTimestamp, "UNLOCK_BEFORE_SWITCH");

        // Get more data about the previous request.
        address previousStrategy = getRequestStrategy[execHash];
        bytes memory previousCalldata = getRequestCalldata[execHash];
        uint256 previousGasLimit = getRequestGasLimit[execHash];

        // Generate a new execHash for the resubmitted request.
        systemNonce += 1;
        newExecHash = NovaExecHashLib.compute({
            nonce: systemNonce,
            strategy: previousStrategy,
            l1Calldata: previousCalldata,
            gasPrice: gasPrice
        });

        // Fill out data for the resubmitted request.
        getRequestCreator[newExecHash] = msg.sender;
        getRequestStrategy[newExecHash] = previousStrategy;
        getRequestCalldata[newExecHash] = previousCalldata;
        getRequestGasLimit[newExecHash] = previousGasLimit;
        getRequestGasPrice[newExecHash] = gasPrice;
        getRequestTip[newExecHash] = getRequestTip[execHash];
        // Storing the nonce is just for convenience; it does not need to be on-chain.
        getRequestNonce[execHash] = systemNonce;

        // Map the resubmitted request to its uncle.
        getRequestUncle[newExecHash] = execHash;

        // Set the uncled request to die in MIN_UNLOCK_DELAY_SECONDS.
        getRequestDeathTimestamp[execHash] = switchTimestamp;

        emit SpeedUpRequest(execHash, newExecHash, systemNonce, switchTimestamp);

        // Transfer in additional ETH to pay for the new gas limit.
        ETH.safeTransferFrom(msg.sender, address(this), gasPrice.sub(previousGasPrice).mul(previousGasLimit));
    }

    /*///////////////////////////////////////////////////////////////
                  CROSS DOMAIN MESSENGER ONLY FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Distributes inputs/tips to the relayer as a result of a successful execution.
    /// @dev Only the linked L1_NovaExecutionManager can call via the cross domain messenger.
    /// @param execHash The computed execHash of the execution.
    /// @param rewardRecipient The address the relayer specified to be the recipient of the tokens on L2.
    /// @param reverted If the strategy reverted on L1 during execution.
    /// @param gasUsed The amount of gas used by the execution tx on L1.
    function execCompleted(
        bytes32 execHash,
        address rewardRecipient,
        bool reverted,
        uint256 gasUsed
    ) external onlyFromCrossDomainAccount(L1_NovaExecutionManagerAddress) {
        // Ensure that this request exists.
        require(getRequestCreator[execHash] != address(0), "NOT_CREATED");
        // Ensure tokens have not already been removed.
        (bool tokensRemoved, ) = areTokensRemoved(execHash);
        require(!tokensRemoved, "TOKENS_REMOVED");

        // Get relevant request data.
        uint256 gasLimit = getRequestGasLimit[execHash];
        uint256 gasPrice = getRequestGasPrice[execHash];
        uint256 tip = getRequestTip[execHash];
        address creator = getRequestCreator[execHash];

        // Give the proper input token recipient the ability to claim the tokens.
        getRequestInputTokenRecipientData[execHash].recipient = reverted ? creator : rewardRecipient;

        // The amount of ETH to pay for the gas used (capped at the gas limit).
        uint256 gasPayment = gasPrice.mul(gasUsed > gasLimit ? gasLimit : gasUsed);

        // The amount of ETH to pay as the tip to the rewardRecipient. If the
        // execution reverted the reward recipient will only receive the tip divided
        // by the PENALTY_TIP_DIVISOR. The creator will be refunded the remaining portion.
        uint256 recipientTip = reverted ? (tip.div(PENALTY_TIP_DIVISOR)) : tip;

        emit ExecCompleted(execHash, rewardRecipient, reverted, gasUsed);

        // Refund the creator any unused gas + refund some of the tip if reverted
        ETH.safeTransfer(creator, gasLimit.mul(gasPrice).sub(gasPayment).add(tip.sub(recipientTip)));
        // Pay the recipient the gas payment + the tip.
        ETH.safeTransfer(rewardRecipient, gasPayment.add(recipientTip));
    }

    /*///////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if the request has had any of its tokens removed.
    /// @param execHash The request to check.
    /// @return tokensRemoved A boolean indicating if the request has had any of its tokens removed.
    /// @return changeTimestamp A timestamp indicating when the request might have one of its tokens removed or added.
    /// Will be 0 if there is no removal/addition expected.
    /// Will also be 0 if the request has had its tokens withdrawn or it has been executed.
    /// It will be a timestamp if the request will have its tokens added soon (it's a resubmitted copy of an uncled request)
    /// or if the request will have its tokens removed soon (its an uncle scheduled to die soon).
    function areTokensRemoved(bytes32 execHash) public view returns (bool tokensRemoved, uint256 changeTimestamp) {
        address inputTokenRecipient = getRequestInputTokenRecipientData[execHash].recipient;
        if (inputTokenRecipient != address(0)) {
            // The request has been executed or had its tokens withdrawn,
            // so we know its tokens are removed and won't be added back.
            return (true, 0);
        }

        uint256 deathTimestamp = getRequestDeathTimestamp[execHash];
        if (deathTimestamp != 0) {
            if (block.timestamp >= deathTimestamp) {
                // This request is an uncle which has died, meaning its tokens
                // have been removed and sent to a resubmitted request.
                return (true, 0);
            } else {
                // This request is an uncle which has not died yet, so we know
                // it has tokens that will be removed on its deathTimestamp.
                return (false, deathTimestamp);
            }
        }

        bytes32 uncleExecHash = getRequestUncle[execHash];
        if (uncleExecHash == "") {
            // This request does not have an uncle and has passed all
            // the previous removal checks, so we know it has tokens.
            return (false, 0);
        }

        address uncleInputTokenRecipient = getRequestInputTokenRecipientData[uncleExecHash].recipient;
        if (uncleInputTokenRecipient != address(0)) {
            // This request is a resubmitted version of its uncle which was
            // executed before the uncle could "die" and switch its tokens
            // to this resubmitted request, so we know it does not have tokens.
            return (true, 0);
        }

        uint256 uncleDeathTimestamp = getRequestDeathTimestamp[uncleExecHash];
        if (uncleDeathTimestamp > block.timestamp) {
            // This request is a resubmitted version of its uncle which has
            // not "died" yet, so we know it does not have its tokens yet,
            // but will receive them after the uncleDeathTimestamp.
            return (true, uncleDeathTimestamp);
        }

        // This is a resubmitted request with an uncle that died properly
        // without being executed early, so we know it has its tokens.
        return (false, 0);
    }

    /// @notice Checks if the request is scheduled to have its tokens unlocked.
    /// @param execHash The request to check.
    /// @return unlocked A boolean indicating if the request has had its tokens unlocked.
    /// @return changeTimestamp A timestamp indicating when the request might have its tokens unlocked.
    /// Will be 0 if there is no unlock is scheduled or it has already unlocked.
    /// It will be a timestamp if an unlock has been scheduled but not completed.
    function areTokensUnlocked(bytes32 execHash) public view returns (bool unlocked, uint256 changeTimestamp) {
        uint256 tokenUnlockTimestamp = getRequestUnlockTimestamp[execHash];

        if (tokenUnlockTimestamp == 0) {
            // There is no unlock scheduled.
            unlocked = false;
            changeTimestamp = 0;
        } else {
            // There has been an unlock scheduled/completed.
            unlocked = block.timestamp >= tokenUnlockTimestamp;
            changeTimestamp = unlocked ? 0 : tokenUnlockTimestamp;
        }
    }
}
