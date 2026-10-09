// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {PullPayments} from "../src/PullPayments.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev A discount module whose release always reverts (audit F16).
contract RevertingReleaseModule {
    address public immutable pawnShop;
    address public immutable pawnToken;

    constructor(address shop_, address token_) {
        pawnShop = shop_;
        pawnToken = token_;
    }

    function commit(uint256, address, uint256 base) external pure returns (uint256) {
        return base;
    }

    function release(uint256) external pure {
        revert("release broken");
    }
}

/// @notice One test (or more) per fix from audit job e4a761c2, including the audit's proofs for F1, F3 and F4.
contract AuditFixesTest is PawnTestBase {
    function _overdue(uint256 id) private {
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _refreshFloor();
    }

    function _auction(uint256 id) private {
        _overdue(id);
        shop.startAuction(id);
    }

    // ---- constructor presets ----

    function test_constructorPresets() public {
        PawnShop fresh = new PawnShop(owner, address(token), address(weth), vm.addr(KEY));
        (,,,, bool enabled, bytes32 hash) = fresh.collections(fresh.IDENTITY_COLLECTION());
        assertTrue(enabled);
        assertEq(hash, 0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1);
        assertTrue(fresh.newLoansPaused());
        assertEq(fresh.oracleSigner(), vm.addr(KEY));
        assertEq(fresh.owner(), owner);
        assertEq(fresh.lendingPool().owner(), owner);
        // F15: the preset is exempt from the new-loan cooldown.
        assertEq(fresh.loansDisabledUntil(fresh.IDENTITY_COLLECTION()), 0);
    }

    // ---- F1 ----

    /// Audit proof F1: a stale low floor let anyone start an auction and buy it in the same block.
    function test_F1_proof_staleFloorSameBlockSnipeIsBlocked() public {
        uint256 id = _pawn(1, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.05 ether); // a momentary low print
        vm.warp(shop.getLoan(id).due + 3 days + 1); // now stale
        vm.prank(buyer);
        vm.expectRevert(PawnShop.StaleFloor.selector);
        shop.startAuction(id);
        _floor(1 ether);
        vm.prank(buyer);
        shop.startAuction(id);
        vm.prank(buyer);
        vm.expectRevert(PawnShop.SameBlock.selector);
        shop.buyAuction{value: 1 ether}(id, buyer);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        vm.prank(buyer);
        shop.buyAuction{value: price}(id, buyer);
        assertEq(nft.ownerOf(1), buyer);
    }

    // ---- F2 ----

    function test_F2_restartAfterTerminalPeriod() public {
        uint256 id = _pawn(1, 1);
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _floor(0.6 ether);
        shop.startAuction(id);
        uint256 started = shop.getLoan(id).auctionStarted;
        vm.warp(started + 17 days - 1);
        _floor(1 ether);
        vm.expectRevert(PawnShop.NotRestartable.selector);
        shop.restartAuction(id);
        vm.warp(started + 17 days);
        assertEq(shop.auctionPrice(id), 0.3 ether);
        shop.markAuctionLoss(id);
        assertEq(pool.auctionLoss(id), 0.1 ether);
        uint256 lossBefore = pool.auctionLoss(id);
        _floor(2 ether);
        vm.prank(buyer);
        shop.restartAuction(id);
        PawnShop.Loan memory loan = shop.getLoan(id);
        assertEq(loan.auctionStarted, vm.getBlockTimestamp());
        assertEq(loan.auctionFloor, 2 ether);
        assertEq(shop.auctionPrice(id), 2 ether);
        // F4: with collateral held, the restarted (higher) price may lower the allowance.
        assertLt(pool.auctionLoss(id), lossBefore);
        assertEq(pool.auctionLoss(id), 0);
        vm.expectRevert(PawnShop.SameBlock.selector);
        shop.buyAuction{value: 2 ether}(id, buyer);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        uint256 borrowerBefore = shop.claimable(alice);
        shop.buyAuction{value: price}(id, buyer);
        assertEq(shop.claimable(alice) - borrowerBefore, price - 0.4 ether); // borrower surplus
    }

    function test_F2_restartRequiresFreshFloorAndAuction() public {
        uint256 id = _pawn(1, 1);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.restartAuction(id);
        _auction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        vm.expectRevert(PawnShop.StaleFloor.selector);
        shop.restartAuction(id);
    }

    function test_F2_restartAfterWriteOffRoutesProceedsThroughRecovery() public {
        uint256 id = _pawn(1, 1);
        _auction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        _floor(1.5 ether);
        shop.restartAuction(id); // allowed immediately after a write-off
        assertEq(shop.getLoan(id).auctionFloor, 1.5 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        uint256 borrowerBefore = shop.claimable(alice);
        shop.buyAuction{value: price}(id, buyer);
        // Launch review (1753e7e5): a held token is sold through the settlement path, not as a late recovery.
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.cumulativeLoss(), 0);
        assertEq(pool.cumulativeRecoveries(), 0);
        assertEq(shop.claimable(alice) - borrowerBefore, price - 0.4 ether);
        assertEq(nft.ownerOf(1), buyer);
    }

    // ---- F3 ----

    /// Audit proof F3: a seized NFT made the auction price zero and anyone could "buy" it for nothing.
    function test_F3_proof_missingCollateralCannotBeBoughtAtZero() public {
        uint256 id = _pawn(1, 0);
        _auction(id);
        nft.seize(1, buyer);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(shop.auctionPrice(id), 0);
        vm.prank(buyer);
        vm.expectRevert(PawnShop.CollateralMissing.selector);
        shop.buyAuction(id, buyer);
        assertEq(uint256(shop.getLoan(id).status), uint256(PawnShop.Status.Auction));
        shop.writeOffAuction(id); // the settlement path for missing collateral
        assertTrue(shop.writtenOff(id));
        assertEq(pool.totalBorrowed(), 0);
    }

    // ---- F4 ----

    /// Audit proof F4: releasing an allowance larger than the realised loss jumped the share price at once.
    function test_F4_proof_excessAllowanceVestsOverSevenDays() public {
        uint256 id = _pawn(1, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.5 ether);
        vm.warp(shop.getLoan(id).due);
        shop.markOverdue(id); // books 0.4 - 0.25 = 0.15
        assertEq(pool.auctionLoss(id), 0.15 ether);
        uint256 before = pool.totalAssets();
        shop.repay{value: 0.4 ether}(id); // realised loss is zero
        assertEq(pool.expectedAuctionLoss(), 0);
        assertApproxEqAbs(pool.totalAssets(), before, 1);
        assertApproxEqAbs(pool.unvestedRelease(), 0.15 ether, 1);
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        assertApproxEqAbs(pool.unvestedRelease(), 0.075 ether, 1);
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        assertEq(pool.unvestedRelease(), 0);
    }

    function test_F4_lowerAllowanceOnlyWhileCollateralHeld() public {
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.markAuctionLoss(1, 0.4 ether, 0.4 ether, true);
        uint256 id = _pawn(1, 0);
        vm.warp(shop.getLoan(id).due);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.2 ether);
        shop.markOverdue(id); // 0.4 - 0.1 = 0.3
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(1 ether);
        // markOverdue never lowers.
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        shop.markOverdue(id);
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _floor(1 ether);
        shop.startAuction(id); // collateral held: start price 1 ETH lowers the allowance to 0
        assertEq(pool.auctionLoss(id), 0);
    }

    // ---- F5 ----

    function test_F5_markOverdueFromDueOnward() public {
        uint256 id = _pawn(1, 0);
        uint256 due = shop.getLoan(id).due;
        vm.warp(due - 1);
        vm.expectRevert(PawnShop.NotOverdue.selector);
        shop.markOverdue(id);
        vm.warp(due);
        vm.prank(buyer);
        shop.markOverdue(id); // stored floor 1 ETH: min(0.4, 0.5) recovers all, loss 0
        assertEq(pool.auctionLoss(id), 0);
        vm.warp(due + 1);
        _floor(0.3 ether);
        shop.markOverdue(id); // 0.4 - 0.15
        assertEq(pool.auctionLoss(id), 0.25 ether);
        assertEq(pool.expectedAuctionLoss(), 0.25 ether);
        shop.repay{value: 0.4 ether}(id);
        assertEq(pool.expectedAuctionLoss(), 0);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markOverdue(id);
    }

    // ---- F6 ----

    function test_F6_pawnSlippageBounds() public {
        nft.mint(alice, 7);
        vm.startPrank(alice);
        nft.approve(address(shop), 7);
        vm.expectRevert(PawnShop.Slippage.selector);
        shop.pawn(address(nft), 7, 0, 0.4 ether + 1, type(uint256).max);
        vm.expectRevert(PawnShop.Slippage.selector);
        shop.pawn(address(nft), 7, 0, 0, 0.012 ether - 1);
        // The site passes displayed values with 1% tolerance.
        uint256 id = shop.pawn(address(nft), 7, 0, 0.396 ether, 0.01212 ether);
        vm.stopPrank();
        assertEq(shop.getLoan(id).principal, 0.4 ether);
    }

    // ---- F7 ----

    function test_F7_noBountyForBorrowerAndCappedForSmallLoans() public {
        shop.fundBounties{value: 0.1 ether}();
        uint256 id = _pawn(1, 0);
        _overdue(id);
        uint256 reserve = shop.bountyReserve();
        vm.prank(alice);
        shop.startAuction(id);
        assertEq(shop.bountyReserve(), reserve);

        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.03 ether);
        uint256 small = _pawn(2, 1); // principal 0.012
        _overdue(small);
        reserve = shop.bountyReserve();
        uint256 before = shop.claimable(buyer);
        vm.prank(buyer);
        shop.startAuction(small);
        assertEq(shop.claimable(buyer) - before, 0.00012 ether);
        assertEq(reserve - shop.bountyReserve(), 0.00012 ether);
    }

    function test_F7_fullBountyForThirdPartyOnLargeLoan() public {
        shop.fundBounties{value: 0.1 ether}();
        uint256 id = _pawn(1, 0);
        _overdue(id);
        uint256 before = shop.claimable(buyer);
        vm.prank(buyer);
        shop.startAuction(id);
        assertEq(shop.claimable(buyer) - before, shop.AUCTION_BOUNTY());
    }

    // ---- F8 ----

    function test_F8_blockWindowChecks() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        a.fromBlock = 201;
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        a = _attestation(FLOOR_QUESTION, 2 ether);
        sig = _signature(shop, a);
        vm.roll(200 + 7800 + 1);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        vm.roll(200 + 7800);
        shop.submitFloor(address(nft), a, sig);
        (uint256 price,,,) = shop.floors(address(nft));
        assertEq(price, 2 ether);
    }

    // ---- F9 ----

    function test_F9_recoveryRestoresConsumedReserveFirst() public {
        vm.deal(address(shop), 0.1 ether);
        vm.prank(address(shop));
        pool.addReserve{value: 0.1 ether}();
        uint256 reserveStart = pool.shortfallReserve();
        uint256 id = _pawn(1, 1);
        _auction(id);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        // Launch review (1753e7e5): while the token is held the reserve is not consumed; the principal is
        // realised, and the reserve used, once the collateral is gone.
        assertEq(pool.reserveUsed(id), 0);
        assertEq(pool.shortfallReserve(), reserveStart);
        address vault = shop.getLoan(id).vault;
        nft.seize(1, address(0));
        shop.writeOffAuction(id);
        assertTrue(shop.debtRealised(id));
        assertEq(pool.reserveUsed(id), reserveStart);
        assertEq(pool.shortfallReserve(), 0);
        // The token finds its way back to the vault and is sold as a late recovery.
        nft.seize(1, vault);
        _floor(1 ether);
        shop.restartAuction(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        uint256 donationsBefore = pool.unvestedDonations();
        shop.buyAuction{value: price}(id, buyer);
        assertEq(pool.shortfallReserve(), reserveStart);
        assertEq(pool.reserveUsed(id), 0);
        // The remainder of the 0.4 recovery vests to lenders.
        assertApproxEqAbs(pool.unvestedDonations() - donationsBefore, 0.4 ether - reserveStart, 1);
    }

    // ---- F12 ----

    function test_F12_depositCapWindowAndCancel() public {
        vm.prank(owner);
        pool.queueDepositCap(20 ether);
        vm.expectRevert();
        pool.cancelDepositCap();
        vm.warp(vm.getBlockTimestamp() + 48 hours + 7 days + 1);
        vm.expectRevert(LendingPool.WindowExpired.selector);
        pool.executeDepositCap();
        vm.prank(owner);
        pool.queueDepositCap(30 ether);
        vm.prank(owner);
        pool.cancelDepositCap();
        assertEq(pool.pendingCapAt(), 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(LendingPool.TimelockPending.selector);
        pool.executeDepositCap();
        vm.prank(owner);
        pool.queueDepositCap(30 ether);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 7 days);
        pool.executeDepositCap();
        assertEq(pool.depositCap(), 30 ether);
    }

    // ---- F13 ----

    function test_F13_isValidSignatureReturnsFailureWhenTokenBurned() public {
        uint256 id = _pawn(1, 0);
        CollateralVault vault = CollateralVault(payable(shop.getLoan(id).vault));
        CollateralVault.WorkerAuthorization memory m = CollateralVault.WorkerAuthorization(
            keccak256("device"),
            address(vault),
            1,
            keccak256("nonce"),
            uint64(vm.getBlockTimestamp() + 15 minutes),
            "https://api.imd.fun"
        );
        vm.prank(alice);
        vault.authorizeWorker(m);
        bytes32 digest = vault.workerDigest();
        assertEq(vault.isValidSignature(digest, ""), bytes4(0x1626ba7e));
        nft.seize(1, address(0)); // burned: ownerOf reverts
        assertEq(vault.isValidSignature(digest, ""), bytes4(0xffffffff));
    }

    // ---- F14 ----

    function test_F14_receiverCannotBeVaultOrCollection() public {
        uint256 id = _pawn(1, 0);
        _auction(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        address vault = shop.getLoan(id).vault;
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        shop.buyAuction{value: 1 ether}(id, vault);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        shop.buyAuction{value: 1 ether}(id, address(nft));
        shop.buyAuction{value: 1 ether}(id, buyer);
    }

    // ---- F15 ----

    function test_F15_queuedRotationDisablesNewLoansFor48Hours() public {
        bytes32 next = keccak256("rotated question");
        PawnShop.Collection memory c = PawnShop.Collection(4000, 4000, 10000, true, true, next);
        vm.prank(owner);
        shop.queueCollection(address(nft), c);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        shop.executeCollection(address(nft), c);
        assertEq(shop.loansDisabledUntil(address(nft)), vm.getBlockTimestamp() + 48 hours);
        OracleAttestation.Attestation memory a = _attestation(next, 1 ether);
        shop.submitFloor(address(nft), a, _signature(shop, a));
        nft.mint(alice, 9);
        vm.startPrank(alice);
        nft.approve(address(shop), 9);
        vm.expectRevert(PawnShop.QuestionCooldown.selector);
        shop.pawn(address(nft), 9, 0, 0, type(uint256).max);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        a = _attestation(next, 1 ether);
        shop.submitFloor(address(nft), a, _signature(shop, a));
        vm.prank(alice);
        shop.pawn(address(nft), 9, 0, 0, type(uint256).max);
        assertEq(nft.ownerOf(9), shop.getLoan(shop.nextLoanId() - 1).vault);
    }

    // ---- F16 ----

    function test_F16_brokenModuleReleaseDoesNotBlockSettlement() public {
        RevertingReleaseModule module = new RevertingReleaseModule(address(shop), address(token));
        vm.prank(owner);
        shop.queueDiscountModule(address(module));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        shop.executeDiscountModule(address(module));
        _floor(1 ether);
        uint256 repaid = _pawn(1, 0);
        shop.repay{value: 0.4 ether}(repaid);
        assertEq(nft.ownerOf(1), alice);

        uint256 sold = _pawn(2, 1);
        uint256 writtenOff = _pawn(3, 1);
        _overdue(sold);
        shop.startAuction(sold);
        shop.startAuction(writtenOff);
        vm.warp(vm.getBlockTimestamp() + 1);
        shop.buyAuction{value: 1 ether}(sold, buyer);
        assertEq(nft.ownerOf(2), buyer);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(writtenOff);
        assertTrue(shop.writtenOff(writtenOff));
    }

    // ---- F11 ----

    function test_F11_burnAcceptsAtMostOneHourOldAnswers() public {
        MilestoneBurn burnVault = new MilestoneBurn(address(token), owner, vm.addr(KEY), address(shop));
        bytes32 question = keccak256("test-only 24h TWAP FDV question");
        vm.prank(owner);
        burnVault.setQuestionHashOnce(question);
        vm.prank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(keccak256("again"));
        token.transfer(address(burnVault), 10 ether);
        OracleAttestation.Attestation memory a = _attestation(question, 2_000_000 ether);
        bytes memory sig = _signature(burnVault, a);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert(MilestoneBurn.InvalidAttestation.selector);
        burnVault.burn(a, sig);
        vm.warp(vm.getBlockTimestamp() - 1);
        burnVault.burn(a, sig);
        assertTrue(burnVault.burned());
    }
}
