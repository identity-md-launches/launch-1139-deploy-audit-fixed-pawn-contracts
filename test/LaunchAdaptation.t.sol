// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {FloorRelay} from "../src/FloorRelay.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PullPayments} from "../src/PullPayments.sol";
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
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.cumulativeLoss(), 0);
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
        // The sniper gains nothing from the release; bob's shares absorb the whole 0.4 ETH. The sniper also
        // paid as if the still-marked loan two were sound (launch review 548fab74), so until that mark
        // resolves their shares carry a pro-rata part of it.
        assertLe(sniperValue, amount);
        assertGe(bobValue, bobBefore + 0.4 ether - 1e9);
        // Once loan two is repaid and its release has vested, the sniper holds exactly what they paid and
        // bob has both releases.
        vm.prank(alice);
        s.repay{value: 0.5 ether}(two);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(sniper)), amount, 1e9);
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(bob)), bobBefore + 0.8 ether, 1e9);
    }

    function test_depositPricingUnchangedWithoutAnActiveReleaseStream() public {
        assertEq(pool.unvestedRelease(), 0);
        assertEq(pool.previewDeposit(1 ether), pool.convertToShares(1 ether));
        assertApproxEqAbs(pool.previewMint(1e24), pool.convertToAssets(1e24), 1);
        uint256 shares = pool.previewDeposit(1 ether);
        vm.prank(bob);
        assertEq(pool.depositETH{value: 1 ether}(bob), shares);
    }

    // ---- launch review (revision): mark and release accounting ----

    /// high b79122ba: a lowered mark (startAuction at the fresh floor) vests like a settlement release.
    function test_loweredMarkVestsInsteadOfReleasingAtOnce() public {
        uint256 id = _pawn(1, 0);
        PawnShop.Loan memory loan = shop.getLoan(id);
        uint256 bobBefore = pool.previewRedeem(pool.balanceOf(bob));
        vm.warp(loan.due);
        _floor(0.5 ether);
        shop.markOverdue(id);
        assertEq(pool.auctionLoss(id), 0.15 ether);
        vm.prank(buyer);
        uint256 shares = pool.depositETH{value: 5 ether}(buyer);
        vm.warp(loan.due + shop.GRACE() + 1);
        _floor(0.5 ether);
        uint256 before = pool.totalAssets();
        vm.prank(buyer);
        shop.startAuction(id);
        assertEq(pool.auctionLoss(id), 0);
        assertEq(pool.expectedAuctionLoss(), 0);
        assertEq(pool.unvestedRelease(), 0.15 ether);
        assertEq(pool.totalAssets(), before);
        vm.prank(buyer);
        pool.redeemETH(shares, buyer, buyer);
        assertLe(pool.claimable(buyer), 5 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pool.unvestedRelease(), 0);
        assertGe(pool.previewRedeem(pool.balanceOf(bob)), bobBefore);
    }

    /// high b79122ba: a later rise of the allowance cancels the unvested remainder before touching value.
    function test_raisedMarkCancelsTheUnvestedReleaseFirst() public {
        uint256 id = _pawn(1, 0);
        PawnShop.Loan memory loan = shop.getLoan(id);
        vm.warp(loan.due);
        _floor(0.5 ether);
        shop.markOverdue(id);
        _overdue(id);
        shop.startAuction(id);
        assertEq(pool.unvestedRelease(), 0.15 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(shop.auctionPrice(id), 0.35 ether);
        uint256 unvested = pool.unvestedRelease();
        uint256 before = pool.totalAssets();
        shop.markAuctionLoss(id);
        assertEq(pool.auctionLoss(id), 0.05 ether);
        assertEq(pool.unvestedRelease(), unvested - 0.05 ether);
        assertEq(pool.totalAssets(), before);
    }

    /// medium e5e83677: the release stream can never push totalAssets below zero.
    function test_totalAssetsNeverUnderflowsWhileAReleaseVests() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(2.5 ether);
        uint256 a = _pawn(1, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(5 ether);
        uint256 b = _pawn(2, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _floor(1);
        shop.markOverdue(a);
        vm.prank(alice);
        shop.repay{value: 1 ether}(a);
        assertEq(pool.unvestedRelease(), 1 ether);
        vm.startPrank(bob);
        pool.redeemETH(pool.maxRedeem(bob), bob, bob);
        vm.stopPrank();
        shop.markOverdue(b);
        assertEq(pool.expectedAuctionLoss(), 2 ether);
        assertEq(pool.totalAssets(), 0);
        vm.prank(buyer);
        pool.depositETH{value: 1 ether}(buyer);
        assertGt(pool.balanceOf(buyer), 0);
        vm.prank(alice);
        shop.repay{value: 2 ether}(b);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pool.unvestedRelease(), 0);
        assertEq(pool.totalAssets() + pool.shortfallReserve(), weth.balanceOf(address(pool)));
    }

    /// medium 3f291830: an extension makes the loan current and releases its overdue mark through vesting.
    function test_extendReleasesTheOverdueMarkThroughVesting() public {
        uint256 id = _pawn(1, 0);
        PawnShop.Loan memory loan = shop.getLoan(id);
        vm.warp(loan.due);
        _floor(0.5 ether);
        shop.markOverdue(id);
        assertEq(pool.expectedAuctionLoss(), 0.15 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(1 ether);
        uint256 before = pool.totalAssets();
        vm.prank(alice);
        shop.extend{value: 0.012 ether}(id, 0);
        assertEq(pool.auctionLoss(id), 0);
        assertEq(pool.expectedAuctionLoss(), 0);
        assertEq(pool.unvestedRelease(), 0.15 ether);
        assertEq(pool.totalAssets(), before);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertGe(pool.totalAssets(), before + 0.15 ether);
        // A later overdue mark at the new due date is a fresh mark, not a refused decrease.
        vm.warp(shop.getLoan(id).due);
        shop.markOverdue(id);
        assertEq(pool.auctionLoss(id), 0);
    }

    /// medium 548fab74: entries are priced as if outstanding marks were sound, so a deposit between a mark
    /// and its settlement buys none of the release.
    function test_entrantBetweenMarkAndSettlementBuysNoRelease() public {
        uint256 id = _pawn(1, 0);
        PawnShop.Loan memory loan = shop.getLoan(id);
        uint256 bobBefore = pool.previewRedeem(pool.balanceOf(bob));
        vm.warp(loan.due);
        _floor(0.2 ether);
        vm.prank(alice);
        shop.markOverdue(id);
        assertEq(pool.auctionLoss(id), 0.3 ether);
        uint256 room = pool.maxDeposit(alice);
        assertGe(pool.previewMint(pool.previewDeposit(room)), room - 1);
        vm.prank(alice);
        pool.depositETH{value: room}(alice);
        // Immediately after entry the shares are worth less than paid: the mark is priced into redemptions.
        assertLt(pool.previewRedeem(pool.balanceOf(alice)), room);
        vm.warp(loan.due + 1 days);
        vm.prank(alice);
        shop.repay{value: loan.principal}(id);
        assertEq(pool.unvestedRelease(), 0.3 ether);
        vm.warp(loan.due + 8 days);
        assertLe(pool.previewRedeem(pool.balanceOf(alice)), room);
        assertGe(pool.previewRedeem(pool.balanceOf(alice)), room - 1e9);
        assertGe(pool.previewRedeem(pool.balanceOf(bob)), bobBefore);
    }

    /// medium 1753e7e5: a write-off with held collateral keeps the loan as an allowance; a later entrant pays
    /// for the recovery it would otherwise collect.
    function test_writeOffKeepsHeldCollateralAsAnAllowance() public {
        uint256 id = _pawn(1, 0);
        _overdue(id);
        shop.startAuction(id);
        uint256 bobBefore = pool.previewRedeem(pool.balanceOf(bob));
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        assertTrue(shop.writtenOff(id));
        assertFalse(shop.debtRealised(id));
        assertEq(shop.collectionDebt(address(nft)), 0);
        assertEq(pool.totalBorrowed(), 0.4 ether);
        assertEq(pool.cumulativeLoss(), 0);
        assertEq(pool.auctionLoss(id), 0); // terminal price 0.5 ETH covers the 0.4 ETH principal
        assertEq(pool.previewRedeem(pool.balanceOf(bob)), bobBefore);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(id);
        address carol = makeAddr("late entrant");
        vm.deal(carol, 20 ether);
        uint256 room = pool.maxDeposit(carol);
        vm.prank(carol);
        pool.depositETH{value: room}(carol);
        _refreshFloor();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        shop.buyAuction{value: 0.5 ether}(id, carol);
        assertEq(nft.ownerOf(1), carol);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.cumulativeRecoveries(), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertGe(pool.previewRedeem(pool.balanceOf(bob)) + 1, bobBefore);
        assertLe(pool.previewRedeem(pool.balanceOf(carol)), room);
    }

    /// medium 1753e7e5: the unrecovered part of a held write-off is marked, refreshable and released on restart.
    function test_writeOffMarksTheUnrecoveredPartWhileCollateralIsHeld() public {
        uint256 id = _pawn(1, 0);
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _floor(0.5 ether);
        shop.startAuction(id);
        assertEq(pool.auctionLoss(id), 0);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        uint256 before = pool.totalAssets();
        shop.writeOffAuction(id);
        assertEq(pool.auctionLoss(id), 0.15 ether); // 0.4 ETH principal less the 0.25 ETH terminal price
        assertEq(pool.expectedAuctionLoss(), 0.15 ether);
        assertEq(pool.cumulativeLoss(), 0);
        assertEq(pool.totalAssets(), before - 0.15 ether + pool.shortfallReserve());
        shop.markAuctionLoss(id);
        _floor(1 ether);
        shop.restartAuction(id);
        assertEq(pool.auctionLoss(id), 0);
        assertEq(pool.unvestedRelease(), 0.15 ether - pool.shortfallReserve());
    }

    /// medium 1753e7e5: once the collateral is gone the principal is realised, and a token that comes back is
    /// sold as a late recovery (F9).
    function test_writeOffRealisesThePrincipalOnceCollateralIsGone() public {
        uint256 id = _pawn(1, 0);
        _overdue(id);
        shop.startAuction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        address vault = shop.getLoan(id).vault;
        nft.seize(1, address(0));
        shop.writeOffAuction(id);
        assertTrue(shop.debtRealised(id));
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.auctionLoss(id), 0);
        assertEq(pool.cumulativeLoss() + pool.reserveUsed(id), 0.4 ether);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markAuctionLoss(id);
        nft.seize(1, vault);
        _refreshFloor();
        shop.restartAuction(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        vm.prank(buyer);
        shop.buyAuction{value: price}(id, buyer);
        assertEq(pool.cumulativeRecoveries(), 0.4 ether);
        assertEq(nft.ownerOf(1), buyer);
    }

    /// low 977167: a restart every 17 days does not postpone the write-off.
    function test_restartDoesNotPostponeTheWriteOff() public {
        uint256 id = _pawn(1, 0);
        _overdue(id);
        shop.startAuction(id);
        uint256 opened = vm.getBlockTimestamp();
        assertEq(shop.auctionOpenedAt(id), opened);
        vm.warp(opened + shop.RESTART_AFTER());
        _refreshFloor();
        shop.restartAuction(id);
        assertEq(shop.getLoan(id).auctionStarted, opened + shop.RESTART_AFTER());
        assertEq(shop.auctionOpenedAt(id), opened);
        vm.warp(opened + shop.WRITE_OFF_DELAY() - 1);
        vm.expectRevert(PawnShop.GracePeriod.selector);
        shop.writeOffAuction(id);
        vm.warp(opened + shop.WRITE_OFF_DELAY());
        shop.writeOffAuction(id);
        assertTrue(shop.writtenOff(id));
    }

    /// low ce743ba5: no vault of this shop is a valid auction receiver, not only the loan's own.
    function test_buyAuctionRefusesAnyVaultOfThisShop() public {
        uint256 a = _pawn(1, 0);
        uint256 b = _pawn(2, 0);
        address vaultA = shop.getLoan(a).vault;
        address vaultB = shop.getLoan(b).vault;
        assertTrue(shop.vaultFactory().isVault(vaultA) && shop.vaultFactory().isVault(vaultB));
        _overdue(b);
        shop.startAuction(b);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        shop.buyAuction{value: 1 ether}(b, vaultA);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        shop.buyAuction{value: 1 ether}(b, vaultB);
        shop.buyAuction{value: 1 ether}(b, buyer);
        assertEq(nft.ownerOf(2), buyer);
    }
}
