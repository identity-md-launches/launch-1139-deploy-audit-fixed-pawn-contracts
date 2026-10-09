// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {QuestionRotation} from "./helpers/QuestionRotation.sol";
import {Test} from "forge-std/Test.sol";
import {FloorRelay} from "../src/FloorRelay.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {PawnOracleProbe} from "./OracleConsumerConformance.t.sol";
import {MockWETH} from "./helpers/Mocks.sol";
import {LiveRelayVectors} from "./helpers/LiveRelayVectors.sol";

contract BurnRelayProbe is MilestoneBurn {
    constructor(address token, address setter, address signer, address shop)
        MilestoneBurn(token, setter, signer, shop)
    {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

contract FloorRelayTest is Test {
    address constant IMD = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 constant TEST_KEY = 0xA11CE;
    FloorRelay relay;
    PawnOracleProbe shop;
    BurnRelayProbe burnVault;
    LaunchToken token;

    function setUp() public {
        vm.chainId(1);
        relay = new FloorRelay();
        token = new LaunchToken();
        shop = new PawnOracleProbe(address(this), address(token), address(new MockWETH()), address(relay));
        burnVault = new BurnRelayProbe(address(token), address(this), address(relay), address(shop));
    }

    function test_realZeroConsumerSignatureAcceptedByBothConsumerVerifiers() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        vm.warp(a.issuedAt);
        bytes memory packed = abi.encode(a, signature);
        shop.verify(a, packed);
        burnVault.verify(a, packed);
        bytes32 digest = shop.attestationDigest(a);
        vm.prank(address(shop));
        assertEq(relay.isValidSignature(digest, packed), bytes4(0x1626ba7e));
    }

    function test_sitePackingMatchesSolidityAndVerifies() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        bytes memory packed = LiveRelayVectors.sitePackedFloor();
        assertEq(packed, abi.encode(a, signature));
        vm.warp(a.issuedAt);
        shop.verify(a, packed);
        burnVault.verify(a, packed);
    }

    function test_realSignatureCompletesBurnWithExplicitTestQuestion() public {
        // A real large uint oracle answer, NOT a PAWN market-cap assertion. This isolated
        // deployment pins its actual question solely to exercise the unmodified burn path.
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.largeUint();
        vm.warp(a.issuedAt);
        burnVault.setQuestionHashOnce(a.questionHash);
        token.transfer(address(burnVault), 100 ether);
        burnVault.burn(a, abi.encode(a, signature));
        assertTrue(burnVault.burned());
        assertEq(burnVault.burnedAmount(), 100 ether);
        assertTrue(burnVault.consumed(a.requestId));
    }

    /// @dev Launch audit 56506f8c: the service's 24-hour floor answer is accepted and fresh until its signed expiry.
    function test_realFloorWithTwentyFourHourLifetimeIsAccepted() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        vm.warp(a.issuedAt);
        address collection = shop.IDENTITY_COLLECTION();
        QuestionRotation.rotate(shop, collection, a.questionHash);
        shop.submitFloor(collection, a, abi.encode(a, signature));
        (uint256 price,, uint64 expiresAt,) = shop.floors(collection);
        assertEq(price, abi.decode(a.answer, (uint256)));
        assertEq(expiresAt, a.expiresAt);
        assertTrue(shop.floorFresh(collection));
        vm.warp(a.expiresAt + 1);
        assertFalse(shop.floorFresh(collection));
    }

    function test_anotherSignerAndStructMismatchFailBothConsumers() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        vm.warp(a.issuedAt);
        bytes memory packed = abi.encode(a, signature);
        a.figure++;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.verify(a, packed);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        burnVault.verify(a, packed);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_KEY, _digest(a, address(0)));
        packed = abi.encode(a, abi.encodePacked(r, s, v));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.verify(a, packed);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        burnVault.verify(a, packed);
    }

    function test_hashMustBelongToCallerAndChainOne() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        bytes memory packed = abi.encode(a, signature);
        assertEq(relay.isValidSignature(_digest(a, address(shop)), packed), bytes4(0xffffffff));
        vm.prank(address(shop));
        assertEq(relay.isValidSignature(_digest(a, address(burnVault)), packed), bytes4(0xffffffff));
        vm.chainId(2);
        vm.warp(a.issuedAt);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.verify(a, packed);
    }

    function test_fullFloorSubmissionAndOlderIssuedAtRejection() public {
        // Test-only signer substitution in otherwise identical compiled relay runtime.
        // Live vectors above independently prove compatibility with the production signer.
        _testSigner();
        (OracleAttestation.Attestation memory a,) = LiveRelayVectors.floor();
        a.expiresAt = a.issuedAt + 26 hours;
        vm.warp(a.issuedAt);
        address collection = shop.IDENTITY_COLLECTION();
        QuestionRotation.rotate(shop, collection, a.questionHash);
        bytes memory old = _packSigned(a);
        shop.submitFloor(collection, a, old);
        assertTrue(shop.floorFresh(collection));
        assertTrue(shop.consumed(a.requestId));
        OracleAttestation.Attestation memory newer = a;
        newer.requestId = keccak256("newer test answer");
        newer.issuedAt++;
        newer.expiresAt++;
        vm.warp(newer.issuedAt);
        shop.submitFloor(collection, newer, _packSigned(newer));
        (uint256 price, uint64 issuedAt,,) = shop.floors(collection);
        assertEq(issuedAt, newer.issuedAt);
        assertEq(price, abi.decode(a.answer, (uint256)));
        // Equal timestamp with a distinct request cannot replace it either.
        newer.requestId = keccak256("equal test answer");
        bytes memory equal = _packSigned(newer);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(collection, newer, equal);
        (a,) = LiveRelayVectors.floor();
        a.expiresAt = a.issuedAt + 26 hours;
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(collection, a, old);
    }

    function test_governedSwitchAndAutomaticBurnSync() public {
        PawnShop direct = new PawnShop(address(this), address(token), address(new MockWETH()), IMD);
        MilestoneBurn follows = new MilestoneBurn(address(token), address(this), IMD, address(direct));
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.largeUint();
        vm.warp(a.issuedAt - 48 hours);
        direct.queueAttester(address(relay));
        vm.expectRevert(PawnShop.TimelockPending.selector);
        direct.executeAttester(address(relay));
        vm.warp(a.issuedAt);
        direct.executeAttester(address(relay));
        assertEq(follows.oracleSigner(), IMD);
        follows.setQuestionHashOnce(a.questionHash);
        token.transfer(address(follows), 1 ether);
        follows.burn(a, abi.encode(a, signature));
        assertEq(follows.oracleSigner(), address(relay));
    }

    function testFuzz_neverRevertsForArbitraryPayload(bytes32 hash, bytes memory payload) public view {
        bytes4 result = relay.isValidSignature(hash, payload);
        assertTrue(result == 0xffffffff || result == 0x1626ba7e);
    }

    function testFuzz_malformedOffsetsLengthsAndNarrowFields(uint256 value, uint8 word) public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        bytes memory payload = abi.encode(a, signature);
        uint256[12] memory words = [uint256(0), 1, 5, 6, 8, 9, 12, 13, 14, 15, 16, 17];
        uint256 offset = words[word % words.length] * 32;
        assembly ("memory-safe") { mstore(add(add(payload, 32), offset), value) }
        vm.prank(address(shop));
        bytes4 result = relay.isValidSignature(_digest(a, address(shop)), payload);
        assertTrue(result == 0xffffffff || result == 0x1626ba7e);
    }

    function test_everyTruncationAndBadSignatureReturnsFailure() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = LiveRelayVectors.floor();
        bytes memory packed = abi.encode(a, signature);
        for (uint256 n; n < packed.length; ++n) {
            bytes memory truncated = new bytes(n);
            for (uint256 i; i < n; ++i) {
                truncated[i] = packed[i];
            }
            vm.prank(address(shop));
            assertEq(relay.isValidSignature(_digest(a, address(shop)), truncated), bytes4(0xffffffff));
        }
        for (uint256 v; v < 3; ++v) {
            signature[64] = bytes1(uint8(v));
            vm.prank(address(shop));
            assertEq(relay.isValidSignature(_digest(a, address(shop)), abi.encode(a, signature)), bytes4(0xffffffff));
        }
    }

    function _digest(OracleAttestation.Attestation memory a, address consumer) internal pure returns (bytes32) {
        bytes32 sh = keccak256(
            bytes.concat(
                abi.encode(
                    OracleAttestation.TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                uint256(1),
                consumer
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, sh));
    }

    function _packSigned(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_KEY, _digest(a, address(0)));
        return abi.encode(a, abi.encodePacked(r, s, v));
    }

    function _testSigner() internal {
        bytes memory code = address(relay).code;
        bytes20 from = bytes20(IMD);
        bytes20 to = bytes20(vm.addr(TEST_KEY));
        uint256 replacements;
        for (uint256 i; i + 20 <= code.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < 20; ++j) {
                if (code[i + j] != from[j]) match_ = false;
            }
            if (match_) {
                for (uint256 j; j < 20; ++j) {
                    code[i + j] = to[j];
                }
                replacements++;
            }
        }
        assertEq(replacements, 1);
        vm.etch(address(relay), code);
    }
}
