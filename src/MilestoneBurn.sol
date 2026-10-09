// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {IPawnShop} from "./interfaces/IPawn.sol";

/// @notice No owner, withdrawal, or mint power. A setup authority pins the question once.
contract MilestoneBurn is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    error Unauthorized();
    error NotConfigured();
    error InvalidAttestation();
    error MilestoneNotReached();
    error AlreadyBurned();
    error EmptyVault();

    address public constant BURN_DESTINATION = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MILESTONE = 1_000_000 ether;
    /// @notice Audit F11: a market-cap answer is accepted for at most one hour after issue.
    uint256 public constant MAX_ATTESTATION_AGE = 1 hours;
    address public immutable pawnToken;
    address public immutable questionSetter;
    address public immutable pawnShop;
    bytes32 public questionHash;
    bool public burned;
    uint256 public burnedAmount;

    event QuestionHashSet(bytes32 indexed hash);
    event Burned(uint256 amount, uint256 fullyDilutedMarketCap, bytes32 indexed requestId);

    /// @dev Launch rule: the factory rehearses constructors on an empty chain, so this constructor makes no
    /// call to the shop. The token binding is checked on first use in `burn`, and the signer is read from
    /// the shop there as well (`syncSigner`), so `signer_` only needs to be the shop's initial attester.
    constructor(address token_, address setter_, address signer_, address shop_) OracleAttestationConsumer(signer_) {
        if (token_ == address(0) || setter_ == address(0) || shop_ == address(0)) revert Unauthorized();
        pawnToken = token_;
        questionSetter = setter_;
        pawnShop = shop_;
    }

    function setQuestionHashOnce(bytes32 hash) external {
        if (msg.sender != questionSetter || questionHash != bytes32(0) || hash == bytes32(0)) revert Unauthorized();
        questionHash = hash;
        emit QuestionHashSet(hash);
    }

    /// @notice Launch audit (low, c079051d): the oracle's questionHash is per request, so a hash pinned to a
    /// request that never reaches the milestone, or whose answer was not burned within the hour, stranded
    /// the vault's PAWN forever. The setter may re-pin until the burn fires; it still cannot move funds.
    function replaceQuestionHash(bytes32 hash) external {
        if (msg.sender != questionSetter || questionHash == bytes32(0) || hash == bytes32(0) || burned) {
            revert Unauthorized();
        }
        questionHash = hash;
        emit QuestionHashSet(hash);
    }

    function burn(OracleAttestation.Attestation calldata a, bytes calldata signature) external nonReentrant {
        if (burned) revert AlreadyBurned();
        if (questionHash == bytes32(0)) revert NotConfigured();
        if (IPawnShop(pawnShop).pawnToken() != pawnToken) revert Unauthorized();
        if (
            a.questionHash != questionHash || a.chainId != 1 || a.panelSize < 5 || a.quorum < 4 || a.agreed < a.quorum
                || a.agreed > a.panelSize || a.issuedAt > block.timestamp
                || block.timestamp - a.issuedAt > MAX_ATTESTATION_AGE || a.answer.length != 32
        ) revert InvalidAttestation();
        // Read the governed signer on every burn so a retired key cannot race an explicit sync.
        syncSigner();
        _verifyAttestation(a, signature);
        uint256 cap = decodeUint256(a);
        if (cap < MILESTONE) revert MilestoneNotReached();
        uint256 amount = IERC20(pawnToken).balanceOf(address(this));
        if (amount == 0) revert EmptyVault();
        burned = true;
        burnedAmount = amount;
        _consume(a.requestId);
        IERC20(pawnToken).safeTransfer(BURN_DESTINATION, amount);
        emit Burned(amount, cap, a.requestId);
    }

    /// @notice Anyone may mirror the shop's signer after its 48-hour governed rotation.
    function syncSigner() public {
        address signer = IPawnShop(pawnShop).oracleSigner();
        if (signer != oracleSigner) _setOracleSigner(signer);
    }
}
