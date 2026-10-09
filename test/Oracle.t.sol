// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract OracleTest is PawnTestBase {
    function test_freshUpdatesAndOneBountyPer24Hours() public {
        shop.fundBounties{value: 0.2 ether}();
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(2 ether);
        assertEq(shop.claimable(address(this)), 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _floor(3 ether);
        assertEq(shop.claimable(address(this)), 0.001 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(4 ether);
        assertEq(shop.claimable(address(this)), 0.001 ether);
        (uint256 price,,,) = shop.floors(address(nft));
        assertEq(price, 4 ether);
    }

    function test_replayTamperingWrongSignerAndWrongDomain() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        bytes memory sig = _signature(shop, a);
        shop.submitFloor(address(nft), a, sig);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        ++a.issuedAt;
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.submitFloor(address(nft), a, sig);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, shop.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.submitFloor(address(nft), a, abi.encodePacked(r, s, v));
        PawnShop other = new PawnShop(owner, address(token), address(weth), vm.addr(KEY));
        sig = _signature(other, a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.submitFloor(address(nft), a, sig);
    }

    function test_rejectsWrongQuestionChainPanelTypeAndTime() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        a.chainId = 4663;
        _invalid(a);
        a.chainId = 1;
        a.questionHash = keccak256("different question");
        _invalid(a);
        a.questionHash = FLOOR_QUESTION;
        a.panelSize = 4;
        _invalid(a);
        a.panelSize = 5;
        a.quorum = 3;
        _invalid(a);
        a.quorum = 5;
        _invalid(a);
        a.quorum = 4;
        a.agreed = 6;
        _invalid(a);
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp() + 1);
        _invalid(a);
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        shop.submitFloor(address(nft), a, sig);
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
        a.answerType = 0;
        sig = _signature(shop, a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(3), uint8(0)));
        shop.submitFloor(address(nft), a, sig);
        a.answerType = 3;
        a.answer = abi.encode(uint256(0));
        _invalid(a);
        a.answer = abi.encode(uint256(2 ether));
        vm.warp(vm.getBlockTimestamp() + 27 hours);
        _invalid(a);
    }

    function _invalid(OracleAttestation.Attestation memory a) private {
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
    }

    /// @dev Launch audit 56506f8c: any signed lifetime is accepted; a floor is never fresh past its signed expiry.
    function test_floorIsNeverFreshPastItsSignedExpiry() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 1 ether);
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
        bytes memory sig = _signature(shop, a);
        shop.submitFloor(address(nft), a, sig);
        (,, uint64 expiresAt,) = shop.floors(address(nft));
        assertEq(expiresAt, a.expiresAt);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertTrue(shop.floorFresh(address(nft)));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(shop.floorFresh(address(nft)));
        vm.expectRevert(PawnShop.StaleFloor.selector);
        shop.pawn(address(nft), 1, 0, 0, type(uint256).max);
    }

    function test_signedRequestCannotBeReusedWithNewTimestamp() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 1 ether);
        shop.submitFloor(address(nft), a, _signature(shop, a));
        vm.warp(vm.getBlockTimestamp() + 1);
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 26 hours;
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        shop.submitFloor(address(nft), a, sig);
    }
}
