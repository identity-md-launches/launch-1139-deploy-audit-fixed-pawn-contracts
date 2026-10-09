// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {FloorRelay} from "../src/FloorRelay.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LockDiscount} from "../src/LockDiscount.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Tests for the changes made to launch this project through the evm_contracts factory and for
/// the launch audit findings that reproduced. See ADAPTATION.md.
contract LaunchAdaptationTest is PawnTestBase {
    address constant PAWN_TOKEN = 0x4F2BACEE5f2e7cE3F48DFbd635d96E9A8FcbE478;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function _overdue(uint256 id) private {
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _refreshFloor();
    }

    // ---- launch order on an empty chain ----

    /// @dev Mirrors the manifest order: FloorRelay, PawnShop, LockDiscount, MilestoneBurn. No constructor
    /// calls another contract, so the sequence also works where the token and WETH have no code.
    function test_launchOrderDeploysOnEmptyChainWithFactoryAsSender() public {
        address factory = makeAddr("project factory");
        assertEq(PAWN_TOKEN.code.length, 0);
        assertEq(MAINNET_WETH.code.length, 0);
        vm.startPrank(factory);
        FloorRelay relay = new FloorRelay();
        PawnShop launched = new PawnShop(owner, PAWN_TOKEN, MAINNET_WETH, address(relay));
        LockDiscount spare = new LockDiscount(PAWN_TOKEN, address(launched));
        MilestoneBurn burnVault = new MilestoneBurn(PAWN_TOKEN, owner, address(relay), address(launched));
        vm.stopPrank();

        assertEq(launched.owner(), owner);
        assertEq(launched.feeRecipient(), owner);
        assertEq(launched.lendingPool().owner(), owner);
        assertEq(launched.lendingPool().pawnShop(), address(launched));
        assertEq(launched.lendingPool().asset(), MAINNET_WETH);
        assertEq(launched.pawnToken(), PAWN_TOKEN);
        assertEq(launched.oracleSigner(), address(relay));
        assertTrue(launched.newLoansPaused());
        (,,,, bool enabled, bytes32 hash) = launched.collections(launched.IDENTITY_COLLECTION());
        assertTrue(enabled);
        assertEq(hash, launched.IDENTITY_QUESTION_HASH());
        // The shop binds the module it created; the separately deployed instance is a spare until governed in.
        assertTrue(launched.discountModule() != address(spare));
        assertEq(LockDiscount(launched.discountModule()).pawnShop(), address(launched));
        assertEq(spare.pawnShop(), address(launched));
        assertEq(burnVault.pawnShop(), address(launched));
        assertEq(burnVault.oracleSigner(), address(relay));
        assertEq(burnVault.questionSetter(), owner);
        // Nothing was handed to the factory.
        assertTrue(launched.owner() != factory && launched.lendingPool().owner() != factory);

        _checkRuntime(address(relay));
        _checkRuntime(address(launched));
        _checkRuntime(address(launched.lendingPool()));
        _checkRuntime(address(launched.vaultFactory()));
        _checkRuntime(launched.discountModule());
        _checkRuntime(address(spare));
        _checkRuntime(address(burnVault));
        assertLe(type(PawnShop).creationCode.length + 128, 49_152);
        assertLe(type(MilestoneBurn).creationCode.length + 128, 49_152);
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    // ---- high da7976ab: per-request question hashes ----

    function test_ownerApprovedRequestHashAdmitsFreshFloorWithoutCooldown() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bytes32 todays = keccak256("same question, today's block window");
        OracleAttestation.Attestation memory a = _attestation(todays, 1.2 ether);
        // Before approval the exact pin refuses it.
        {
            bytes memory sig_ = _signature(shop, a);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), a, sig_);
        }

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        shop.approveQuestionHash(address(nft), todays);
        vm.prank(owner);
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.approveQuestionHash(address(nft), bytes32(0));
        vm.prank(owner);
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.approveQuestionHash(makeAddr("unconfigured collection"), todays);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit PawnShop.QuestionHashApproved(address(nft), todays);
        shop.approveQuestionHash(address(nft), todays);
        assertEq(shop.approvedQuestionHash(address(nft)), todays);

        shop.submitFloor(address(nft), a, _signature(shop, a));
        (uint256 price,,,) = shop.floors(address(nft));
        assertEq(price, 1.2 ether);
        assertTrue(shop.floorFresh(address(nft)));
        // No F15 cooldown: lending continues the same block, against the admitted price.
        assertEq(shop.loansDisabledUntil(address(nft)), 0);
        uint256 id = _pawn(1, 0);
        assertEq(shop.getLoan(id).principal, 0.48 ether);

        // A request id is consumed, and tomorrow's request has yet another hash.
        {
            bytes memory sig_ = _signature(shop, a);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), a, sig_);
        }
        OracleAttestation.Attestation memory b = _attestation(keccak256("tomorrow's window"), 1.3 ether);
        b.issuedAt = uint64(vm.getBlockTimestamp() + 1);
        vm.warp(b.issuedAt);
        {
            bytes memory sig_ = _signature(shop, b);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), b, sig_);
        }
        // The governed pin keeps working alongside the approval.
        _floor(1.1 ether);
        (price,,,) = shop.floors(address(nft));
        assertEq(price, 1.1 ether);
    }

    function test_approvedHashStillObeysEveryOtherFloorRule() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bytes32 todays = keccak256("approved window");
        vm.prank(owner);
        shop.approveQuestionHash(address(nft), todays);
        OracleAttestation.Attestation memory a = _attestation(todays, 1 ether);
        a.agreed = 3;
        {
            bytes memory sig_ = _signature(shop, a);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), a, sig_);
        }
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp() - 26 hours - 1);
        {
            bytes memory sig_ = _signature(shop, a);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), a, sig_);
        }
        a.issuedAt = uint64(vm.getBlockTimestamp());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, shop.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        shop.submitFloor(address(nft), a, abi.encodePacked(r, s, v));
    }

    function test_governedRotationClearsTheApproval() public {
        bytes32 todays = keccak256("approved window");
        vm.prank(owner);
        shop.approveQuestionHash(address(nft), todays);
        (uint16 b0, uint16 b1, uint16 share, bool isSeat, bool enabled,) = shop.collections(address(nft));
        PawnShop.Collection memory c =
            PawnShop.Collection(b0, b1, share, isSeat, enabled, keccak256("rotated question"));
        vm.prank(owner);
        shop.queueCollection(address(nft), c);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        shop.executeCollection(address(nft), c);
        assertEq(shop.approvedQuestionHash(address(nft)), bytes32(0));
        OracleAttestation.Attestation memory a = _attestation(todays, 1 ether);
        {
            bytes memory sig_ = _signature(shop, a);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), a, sig_);
        }
    }

    // ---- low 56506f8c: signed lifetime ----

    function test_twentyFourHourAnswerIsAcceptedAndFreshUntilItsSignedExpiry() public {
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 1);
        a.expiresAt = a.issuedAt + 86400;
        vm.warp(a.issuedAt);
        shop.submitFloor(address(nft), a, _signature(shop, a));
        (uint256 price,, uint64 expiresAt,) = shop.floors(address(nft));
        assertEq(price, 2 ether);
        assertEq(expiresAt, a.expiresAt);
        vm.warp(a.expiresAt);
        assertTrue(shop.floorFresh(address(nft)));
        vm.warp(a.expiresAt + 1);
        assertFalse(shop.floorFresh(address(nft)));
        // A lifetime of zero is still refused: an answer that is already expired cannot replace the floor.
        OracleAttestation.Attestation memory z = _attestation(FLOOR_QUESTION, 3 ether);
        z.issuedAt = uint64(vm.getBlockTimestamp());
        z.expiresAt = z.issuedAt;
        {
            bytes memory sig_ = _signature(shop, z);
            vm.expectRevert(PawnShop.InvalidAttestation.selector);
            shop.submitFloor(address(nft), z, sig_);
        }
    }

    // ---- medium bf57e268: written-off restart griefing ----

    function test_writtenOffAuctionCannotBeRestartedEveryBlock() public {
        uint256 id = _pawn(1, 0);
        _overdue(id);
        shop.startAuction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        assertTrue(shop.writtenOff(id));
        _refreshFloor();
        assertEq(shop.auctionPrice(id), 0.5 ether);

        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        shop.restartAuction(id); // 40 days after the start: the interval has long passed
        uint256 restarted = vm.getBlockTimestamp();
        vm.warp(restarted + 1);
        vm.prank(griefer);
        vm.expectRevert(PawnShop.NotRestartable.selector);
        shop.restartAuction(id);
        vm.warp(restarted + shop.RESTART_AFTER() - 1);
        _refreshFloor();
        vm.prank(griefer);
        vm.expectRevert(PawnShop.NotRestartable.selector);
        shop.restartAuction(id);
        // Meanwhile the decayed price is purchasable and the recovery reaches the pool.
        uint256 price = shop.auctionPrice(id);
        assertEq(price, 0.5 ether);
        vm.prank(buyer);
        shop.buyAuction{value: price}(id, buyer);
        assertEq(pool.cumulativeRecoveries(), 0.4 ether);
        assertEq(nft.ownerOf(1), buyer);
    }

    function test_writtenOffRestartAllowedAgainAfterInterval() public {
        uint256 id = _pawn(1, 0);
        _overdue(id);
        shop.startAuction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        _refreshFloor();
        shop.restartAuction(id);
        uint256 restarted = vm.getBlockTimestamp();
        vm.warp(restarted + shop.RESTART_AFTER());
        _floor(1.5 ether);
        shop.restartAuction(id);
        assertEq(shop.getLoan(id).auctionFloor, 1.5 ether);
        assertEq(shop.getLoan(id).auctionStarted, vm.getBlockTimestamp());
    }

    // ---- medium 0ac9b173: release vesting captured by a new depositor ----

    function test_depositDuringReleaseStreamCapturesNoneOfTheRelease() public {
        // Fresh pool: bob is the only lender with 1 ETH.
        PawnShop s = new PawnShop(owner, address(token), address(weth), vm.addr(KEY));
        shop = s;
        pool = s.lendingPool();
        vm.prank(owner);
        s.setNewLoansPaused(false);
        _floor(1.25 ether);
        vm.prank(bob);
        pool.depositETH{value: 1 ether}(bob);
        uint256 one = _pawn(1, 0);
        uint256 two = _pawn(2, 0);
        assertEq(s.getLoan(one).principal, 0.5 ether);
        vm.warp(s.getLoan(one).due + 1);
        _floor(0.2 ether);
        s.markOverdue(one);
        s.markOverdue(two);
        assertEq(pool.expectedAuctionLoss(), 0.8 ether);
        uint256 depressed = pool.totalAssets();
        assertLt(depressed, 0.3 ether);

        vm.prank(alice);
        s.repay{value: 0.5 ether}(one);
        assertEq(pool.unvestedRelease(), 0.4 ether);
        assertEq(pool.totalAssets(), depressed);
        uint256 bobBefore = pool.previewRedeem(pool.balanceOf(bob));

        address sniper = makeAddr("sniper");
        vm.deal(sniper, 20 ether);
        uint256 amount = pool.maxDeposit(sniper);
        // Entry is priced on the fully vested value, so previewDeposit is below the vesting conversion.
        assertLt(pool.previewDeposit(amount), pool.convertToShares(amount));
        assertGe(pool.previewMint(pool.previewDeposit(amount)), amount - 1);
        assertEq(pool.maxMint(sniper), pool.previewDeposit(amount));
        vm.prank(sniper);
        pool.depositETH{value: amount}(sniper);
        // Immediately after entry the sniper's shares are worth less than paid: the unvested part is not theirs.
        assertLt(pool.previewRedeem(pool.balanceOf(sniper)), amount);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 sniperValue = pool.previewRedeem(pool.balanceOf(sniper));
        uint256 bobValue = pool.previewRedeem(pool.balanceOf(bob));
        // The sniper gets back what they put in (within rounding); bob's shares absorb the whole 0.4 ETH release.
        assertLe(sniperValue, amount);
        assertGe(sniperValue, amount - 1e9);
        assertGe(bobValue, bobBefore + 0.4 ether - 1e9);
        assertLe(bobValue, bobBefore + 0.4 ether + 1e9);
    }

    function test_depositPricingUnchangedWithoutAnActiveReleaseStream() public {
        assertEq(pool.unvestedRelease(), 0);
        assertEq(pool.previewDeposit(1 ether), pool.convertToShares(1 ether));
        assertApproxEqAbs(pool.previewMint(1e24), pool.convertToAssets(1e24), 1);
        uint256 shares = pool.previewDeposit(1 ether);
        vm.prank(bob);
        assertEq(pool.depositETH{value: 1 ether}(bob), shares);
    }
}
