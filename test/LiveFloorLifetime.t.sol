// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FloorRelay} from "../src/FloorRelay.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @notice Launch audit finding 56506f8c (low). The only authentic identity.md floor attestation ever issued (request
/// 62702d2a-1a38-4543-93cc-7ece5ac20a66, signed by the IMD attester in the zero-consumer
/// chain-1 domain, validForSeconds = 86400) is rejected by PawnShop.submitFloor because the
/// contract formerly demanded expiresAt - issuedAt >= 26 hours. The relay and the consumer verifier accept
/// the signature; submitFloor now accepts any signed lifetime and floorFresh bounds freshness.
contract LiveFloorLifetimeTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant TOKEN = 0x4F2BACEE5f2e7cE3F48DFbd635d96E9A8FcbE478;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    FloorRelay relay;
    PawnShop shop;

    function setUp() public {
        vm.chainId(1);
        relay = new FloorRelay();
        shop = new PawnShop(OWNER, TOKEN, WETH, address(relay));
    }

    function _live() internal pure returns (OracleAttestation.Attestation memory a, bytes memory signature) {
        a.requestId = 0x62702d2a1a38454393cc7ece5ac20a6600000000000000000000000000000000;
        a.chainId = 1;
        a.questionHash = 0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1;
        a.answerType = 3;
        a.answer = hex"0000000000000000000000000000000000000000000000001a7f319fee8a9400";
        a.figure = 0;
        a.fromBlock = 26140713;
        a.toBlock = 26147885;
        a.blockHash = 0xfc79b216ead714f0c5b6e88f5b926a23e059fdb7c27f03688a308bd008d296ab;
        a.panelJobId = 0x47aaeffbc4234656963e62b522d2f54d00000000000000000000000000000000;
        a.panelSize = 20;
        a.quorum = 14;
        a.agreed = 14;
        a.issuedAt = 1791465279;
        a.expiresAt = 1791551679; // issuedAt + 86400: the service's 24-hour validity
        signature =
            hex"fe65fe854743a69c90a5dd5e538012a432119741ca021341fd939f22a63243e324dc97529e350c504da48f0470937e235818a468862601e811e3742038f9cd751c";
    }

    function test_authenticFloorAttestationIsAccepted() public {
        (OracleAttestation.Attestation memory a, bytes memory signature) = _live();
        vm.warp(a.issuedAt + 60);
        vm.roll(a.toBlock + 10);
        address collection = shop.IDENTITY_COLLECTION();
        assertEq(shop.oracleSigner(), address(relay));
        // The signature itself is valid for this consumer through the relay.
        bytes32 digest = shop.attestationDigest(a);
        vm.prank(address(shop));
        assertEq(relay.isValidSignature(digest, abi.encode(a, signature)), bytes4(0x1626ba7e));

        shop.submitFloor(collection, a, abi.encode(a, signature));

        (uint256 price,, uint64 expiresAt,) = shop.floors(collection);
        assertEq(price, abi.decode(a.answer, (uint256)));
        assertEq(expiresAt, a.expiresAt);
        assertTrue(shop.floorFresh(collection));
    }
}
