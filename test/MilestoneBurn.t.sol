// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract MilestoneBurnTest is PawnTestBase {
    bytes32 constant BURN_QUESTION = keccak256("test-only FDV question");
    MilestoneBurn burnVault;

    function setUp() public override {
        super.setUp();
        burnVault = new MilestoneBurn(address(token), owner, vm.addr(KEY), address(shop));
    }

    function _configure() private {
        vm.prank(owner);
        burnVault.setQuestionHashOnce(BURN_QUESTION);
    }

    function test_unsetOneTimeSetupAndThreshold() public {
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 1_000_000 ether);
        bytes memory sig = _signature(burnVault, a);
        vm.expectRevert(MilestoneBurn.NotConfigured.selector);
        burnVault.burn(a, sig);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(BURN_QUESTION);
        _configure();
        vm.prank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(keccak256("changed"));
        vm.expectRevert(MilestoneBurn.EmptyVault.selector);
        burnVault.burn(a, sig);
        token.transfer(address(burnVault), 100 ether);
        a.answer = abi.encode(uint256(1_000_000 ether - 1));
        sig = _signature(burnVault, a);
        vm.expectRevert(MilestoneBurn.MilestoneNotReached.selector);
        burnVault.burn(a, sig);
        a.answer = abi.encode(uint256(1_000_000 ether));
        sig = _signature(burnVault, a);
        vm.prank(buyer);
        burnVault.burn(a, sig);
        assertTrue(burnVault.burned());
        assertEq(burnVault.burnedAmount(), 100 ether);
        assertEq(token.balanceOf(burnVault.BURN_DESTINATION()), 100 ether);
        assertEq(token.totalSupply(), 1e27); // A sink transfer never changes the fixed launch supply.
        token.transfer(address(burnVault), 1 ether);
        vm.expectRevert(MilestoneBurn.AlreadyBurned.selector);
        burnVault.burn(a, sig);
        assertEq(token.balanceOf(address(burnVault)), 1 ether);
    }

    function test_rejectsStaleExpiredWrongDomainAndInsufficientPanel() public {
        _configure();
        token.transfer(address(burnVault), 100 ether);
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 1_000_000 ether);
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        burnVault.burn(a, sig);
        a.agreed = 3;
        sig = _signature(burnVault, a);
        vm.expectRevert(MilestoneBurn.InvalidAttestation.selector);
        burnVault.burn(a, sig);
        a.agreed = 4;
        a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
        sig = _signature(burnVault, a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        burnVault.burn(a, sig);
        a.expiresAt = uint64(vm.getBlockTimestamp() + 30 days);
        sig = _signature(burnVault, a);
        vm.warp(vm.getBlockTimestamp() + 26 hours + 1);
        vm.expectRevert(MilestoneBurn.InvalidAttestation.selector);
        burnVault.burn(a, sig);
    }

    function test_rotationFollowsShopTimelockWithoutOwnerOrWithdrawalPower() public {
        _configure();
        token.transfer(address(burnVault), 100 ether);
        address next = vm.addr(0xB0B);
        vm.prank(owner);
        shop.queueAttester(next);
        burnVault.syncSigner();
        assertEq(burnVault.oracleSigner(), vm.addr(KEY));
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeAttester(next);
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 1_000_000 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, burnVault.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        burnVault.burn(a, abi.encodePacked(r, s, v));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        shop.executeAttester(next);
        a = _attestation(BURN_QUESTION, 1_000_000 ether);
        bytes memory oldSignature = _signature(burnVault, a);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        burnVault.burn(a, oldSignature);
        // No explicit sync is needed: burn always checks the shop's current signer.
        (v, r, s) = vm.sign(0xB0B, burnVault.attestationDigest(a));
        burnVault.burn(a, abi.encodePacked(r, s, v));
        assertEq(burnVault.oracleSigner(), next);
        assertEq(burnVault.burnedAmount(), 100 ether);
        assertEq(token.balanceOf(address(burnVault)), 0);
    }

    /// @dev Launch rule: constructors make no external calls, so the shop binding is checked on first use.
    function test_unrelatedSignerIsReplacedAndWrongTokenIsRefusedOnFirstUse() public {
        MilestoneBurn wrongSigner = new MilestoneBurn(address(token), owner, buyer, address(shop));
        assertEq(wrongSigner.oracleSigner(), buyer);
        vm.prank(owner);
        wrongSigner.setQuestionHashOnce(BURN_QUESTION);
        token.transfer(address(wrongSigner), 100 ether);
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 1_000_000 ether);
        // burn reads the shop's governed signer, so the stale constructor signer is never used.
        wrongSigner.burn(a, _signature(wrongSigner, a));
        assertEq(wrongSigner.oracleSigner(), vm.addr(KEY));
        assertTrue(wrongSigner.burned());

        MilestoneBurn wrongToken = new MilestoneBurn(address(weth), owner, vm.addr(KEY), address(shop));
        vm.prank(owner);
        wrongToken.setQuestionHashOnce(BURN_QUESTION);
        a = _attestation(BURN_QUESTION, 1_000_000 ether);
        {
            bytes memory sig_ = _signature(wrongToken, a);
            vm.expectRevert(MilestoneBurn.Unauthorized.selector);
            wrongToken.burn(a, sig_);
        }
    }

    function test_constructorNeedsNoLiveShopAndBurnChecksItLater() public {
        address emptyShop = makeAddr("shop with no code yet");
        MilestoneBurn early = new MilestoneBurn(address(token), owner, vm.addr(KEY), emptyShop);
        assertEq(early.pawnShop(), emptyShop);
        vm.prank(owner);
        early.setQuestionHashOnce(BURN_QUESTION);
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 1_000_000 ether);
        {
            bytes memory sig_ = _signature(early, a);
            vm.expectRevert();
            early.burn(a, sig_);
        }
    }

    function test_setterMayRepinUntilBurned() public {
        bytes32 second = keccak256("the request that actually reached the milestone");
        vm.prank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(second); // nothing pinned yet
        _configure();
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(second); // not the setter
        vm.prank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(bytes32(0));
        token.transfer(address(burnVault), 100 ether);
        // The first pin went to a request whose answer missed the milestone: the vault is not stranded.
        OracleAttestation.Attestation memory low = _attestation(BURN_QUESTION, 1_000_000 ether - 1);
        {
            bytes memory sig_ = _signature(burnVault, low);
            vm.expectRevert(MilestoneBurn.MilestoneNotReached.selector);
            burnVault.burn(low, sig_);
        }
        vm.prank(owner);
        burnVault.replaceQuestionHash(second);
        assertEq(burnVault.questionHash(), second);
        OracleAttestation.Attestation memory a = _attestation(BURN_QUESTION, 2_000_000 ether);
        {
            bytes memory sig_ = _signature(burnVault, a);
            vm.expectRevert(MilestoneBurn.InvalidAttestation.selector);
            burnVault.burn(a, sig_);
        }
        a = _attestation(second, 2_000_000 ether);
        burnVault.burn(a, _signature(burnVault, a));
        assertEq(token.balanceOf(burnVault.BURN_DESTINATION()), 100 ether);
        vm.prank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(keccak256("after the burn"));
    }
}
