// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract ReviewRegressionTest is PawnTestBase {
    function _default(uint256 id) private {
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _refreshFloor();
        shop.startAuction(id);
    }

    function test_certainLossBeforeExitAndLaterSettlement() public {
        vm.prank(buyer);
        pool.depositETH{value: 5 ether}(buyer);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(10 ether);
        uint256 id = _pawn(1, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(2 ether);
        _default(id);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 2 ether, 1e13);
        assertApproxEqAbs(pool.totalAssets(), 8.034 ether, 1e13);
        uint256 exit = pool.maxWithdraw(bob);
        assertApproxEqAbs(exit, 4.017 ether, 1);
        vm.prank(bob);
        pool.withdraw(exit, bob, bob);
        vm.warp(vm.getBlockTimestamp() + 1);
        shop.buyAuction{value: 2 ether}(id, buyer);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 0, 1e13);
        assertEq(pool.totalBorrowed(), 0);
        assertApproxEqAbs(pool.cumulativeLoss(), 2 ether, 1e13);
        assertApproxEqAbs(pool.maxWithdraw(buyer), 4.017 ether, 1e13);
    }

    function test_lossMarksNetReserveAndReconcileMultipleAuctions() public {
        vm.deal(address(shop), 0.15 ether);
        vm.prank(address(shop));
        pool.addReserve{value: 0.15 ether}();
        uint256 first = _pawn(1, 1);
        uint256 second = _pawn(2, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.3 ether);
        _default(first);
        shop.startAuction(second);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 0.2 ether, 1e13);
        assertApproxEqAbs(pool.shortfallReserve(), 0.15 ether, 1e13);
        assertApproxEqAbs(pool.totalAssets(), 4.9568 ether, 1e13);
        uint256 assets = pool.totalAssets();
        vm.warp(vm.getBlockTimestamp() + 1);
        shop.buyAuction{value: 0.3 ether}(first, buyer);
        assertApproxEqAbs(pool.totalAssets(), assets, 1e13);
        assertApproxEqAbs(pool.shortfallReserve(), 0.05 ether, 1e13);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 0.1 ether, 1e13);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        shop.markAuctionLoss(second);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 0.25 ether, 1e13);
        assertApproxEqAbs(pool.totalAssets(), assets - 0.15 ether, 1e13);
        shop.markAuctionLoss(second); // Idempotent accounting refresh.
        shop.buyAuction{value: 0.15 ether}(second, buyer);
        assertApproxEqAbs(pool.totalAssets(), assets - 0.15 ether, 1e13);
        assertApproxEqAbs(pool.expectedAuctionLoss(), 0, 1e13);
        assertApproxEqAbs(pool.shortfallReserve(), 0, 1e13);
        assertApproxEqAbs(pool.cumulativeLoss(), 0.2 ether, 1e13);
    }

    function test_writeOffUnsoldAuctionUnlocksAndLateRecoveryVests() public {
        _lock(1_000_000 ether);
        uint256 id = _pawn(1, 1);
        _default(id);
        uint256 started = shop.getLoan(id).auctionStarted;
        vm.warp(started + 40 days - 1);
        vm.expectRevert(PawnShop.GracePeriod.selector);
        shop.writeOffAuction(id);
        vm.warp(started + 40 days);
        uint256 beforeLoss = pool.totalAssets();
        shop.writeOffAuction(id);
        assertTrue(shop.writtenOff(id));
        assertFalse(shop.debtRealised(id));
        // Launch review (1753e7e5): the held token stays sellable, so the pool keeps the loan as an
        // expected-loss allowance (principal less the terminal price, here nothing) instead of a realised loss.
        assertEq(pool.totalBorrowed(), 0.4 ether);
        assertEq(shop.collectionDebt(address(nft)), 0);
        assertEq(discount.committed(alice), 0);
        assertEq(pool.auctionLoss(id), 0);
        assertEq(pool.totalAssets(), beforeLoss);
        assertEq(pool.cumulativeLoss(), 0);
        assertEq(nft.ownerOf(1), shop.getLoan(id).vault);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(id);
        shop.markAuctionLoss(id); // the allowance may still be refreshed
        shop.buyAuction{value: 0.5 ether}(id, buyer);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(pool.cumulativeRecoveries(), 0);
        assertEq(pool.cumulativeLoss(), 0);
        assertEq(pool.totalAssets(), beforeLoss);
        assertEq(pool.totalBorrowed(), 0);
    }

    function test_stuckAuctionLossSharedAfterWriteOff() public {
        vm.prank(buyer);
        pool.depositETH{value: 5 ether}(buyer);
        uint256 id = _pawn(1, 1);
        _default(id);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        shop.writeOffAuction(id);
        // Held collateral at the terminal price covers the principal: no loss is booked yet.
        assertApproxEqAbs(pool.maxWithdraw(bob), 5.0017 ether, 1);
        nft.seize(1, address(0));
        shop.writeOffAuction(id); // the collateral is gone: the principal is realised
        assertApproxEqAbs(pool.maxWithdraw(bob), 4.8017 ether, 1);
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.redeemETH(shares, bob, bob);
        assertApproxEqAbs(pool.maxWithdraw(buyer), 4.8017 ether, 1);
    }

    function test_missingNFTRepaysAndClearsCommitment() public {
        _lock(1_000_000 ether);
        uint256 id = _pawn(1, 0);
        nft.seize(1, address(0));
        shop.repay{value: 0.4 ether}(id);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(discount.committed(alice), 0);
        assertEq(shop.collectionDebt(address(nft)), 0);
        assertTrue(CollateralVault(payable(shop.getLoan(id).vault)).released());
    }

    function test_seizedNFTZeroPriceBooksGapWithoutPayingIssuer() public {
        _lock(1_000_000 ether);
        uint256 id = _pawn(1, 0);
        nft.seize(1, buyer);
        _default(id);
        assertEq(shop.auctionPrice(id), 0);
        assertEq(pool.expectedAuctionLoss(), 0.4 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        // Audit F3: no zero-price sale; writeOffAuction is the settlement path for missing collateral.
        vm.expectRevert(PawnShop.CollateralMissing.selector);
        shop.buyAuction{value: 1 ether}(id, alice);
        shop.writeOffAuction(id);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.cumulativeLoss(), 0.4 ether);
        assertEq(pool.expectedAuctionLoss(), 0);
        assertEq(shop.claimable(address(this)), 0);
        assertEq(discount.committed(alice), 0);
        assertEq(nft.ownerOf(1), buyer);
    }

    function test_missingCollateralCanBeWrittenOffImmediately() public {
        uint256 id = _pawn(1, 1);
        _default(id);
        nft.seize(1, address(0));
        shop.writeOffAuction(id);
        assertEq(pool.totalBorrowed(), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        // Audit F3: missing collateral is never sold at a zero price.
        vm.expectRevert(PawnShop.CollateralMissing.selector);
        shop.buyAuction(id, buyer);
        assertEq(pool.cumulativeLoss(), 0.4 ether);
        assertEq(pool.cumulativeRecoveries(), 0);
    }

    function test_transferRestrictionDoesNotBlockFinancialWriteOff() public {
        _lock(1_000_000 ether);
        uint256 id = _pawn(1, 1);
        _default(id);
        nft.setFailTransfers(true);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        shop.writeOffAuction(id);
        assertEq(shop.collectionDebt(address(nft)), 0);
        assertEq(pool.totalBorrowed(), 0.4 ether);
        assertEq(discount.committed(alice), 0);
        vm.expectRevert("mock transfer failed");
        shop.buyAuction{value: 0.5 ether}(id, buyer);
        assertEq(pool.totalBorrowed(), 0.4 ether);
        nft.setFailTransfers(false);
        shop.buyAuction{value: 0.5 ether}(id, buyer);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.cumulativeLoss(), 0);
    }

    function test_onlyShopCanMarkOrSettleDebt() public {
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.markAuctionLoss(1, 1 ether, 0, false);
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.settleAuction(1, 1 ether);
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.receiveRecovery{value: 1 ether}(1);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(1);
    }

    function test_newQueueSupersedesAndExpires() public {
        vm.startPrank(owner);
        shop.queueAttester(alice);
        shop.queueAttester(buyer);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeAttester(alice);
        shop.executeAttester(buyer);
        vm.prank(owner);
        shop.queueFeeRecipient(alice);
        vm.warp(vm.getBlockTimestamp() + 9 days + 1);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeFeeRecipient(alice);
        vm.prank(owner);
        shop.queueFeeRecipient(alice);
        vm.warp(vm.getBlockTimestamp() + 9 days);
        shop.executeFeeRecipient(alice); // Last second of execution window is valid.
        assertEq(shop.feeRecipient(), alice);
    }

    function test_disablingCollectionCancelsQueuedReenable() public {
        PawnShop.Collection memory c = PawnShop.Collection(4000, 4000, 10000, true, true, FLOOR_QUESTION);
        vm.startPrank(owner);
        shop.queueCollection(address(nft), c);
        shop.disableCollection(address(nft));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeCollection(address(nft), c);
    }

    /// @dev Launch audit 56506f8c: a short-lived newer answer is accepted and its signed expiry is never extended.
    function test_shortExpiryFloorStopsLendingAtItsSignedExpiry() public {
        uint256 id = _pawn(1, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 1 ether);
        a.expiresAt = a.issuedAt + 60;
        bytes memory sig = _signature(shop, a);
        shop.submitFloor(address(nft), a, sig);
        (,, uint64 stored,) = shop.floors(address(nft));
        assertEq(stored, a.expiresAt);
        vm.warp(vm.getBlockTimestamp() + 60);
        assertTrue(shop.floorFresh(address(nft)));
        vm.prank(alice);
        shop.extend{value: 0.004 ether}(id, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(shop.floorFresh(address(nft)));
        vm.prank(alice);
        vm.expectRevert(PawnShop.StaleFloor.selector);
        shop.extend{value: 0.004 ether}(id, 1);
    }

    function test_feeSandwichHasNoImmediateGainAndFeeVests() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(10 ether);
        vm.prank(buyer);
        pool.depositETH{value: 5 ether}(buyer);
        _pawn(1, 0);
        assertEq(pool.unvestedDonations(), 0.102 ether);
        uint256 shares = pool.balanceOf(buyer);
        vm.prank(buyer);
        assertEq(pool.redeemETH(shares, buyer, buyer), 5 ether);
        assertEq(pool.totalAssets(), 5 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pool.totalAssets(), 5.102 ether);
    }

    function test_longSignedExpiryCannotVetoDailyUpdates() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        a.expiresAt = a.issuedAt + 30 days;
        shop.submitFloor(address(nft), a, _signature(shop, a));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _floor(1 ether); // 26-hour validity replaces the longer expiry, keeping the effective age window.
        (uint256 price,, uint64 expiry,) = shop.floors(address(nft));
        assertEq(price, 1 ether);
        assertEq(expiry, vm.getBlockTimestamp() + 26 hours);
        assertTrue(shop.floorFresh(address(nft)));
    }

    function test_emptyPoolDonationRejectedAndFeeGoesToReserve() public {
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.redeemETH(shares, bob, bob);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.donate{value: 1 ether}();
        vm.deal(address(shop), 1 ether);
        vm.prank(address(shop));
        pool.receiveFee{value: 1 ether}();
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.shortfallReserve(), 1 ether);
        assertEq(pool.depositETH{value: 1 ether}(buyer), 1e24);
        assertEq(pool.maxWithdraw(buyer), 1 ether);
    }

    function test_lastShareExitRetiresVestingAndNewStreamStillWorks() public {
        pool.donate{value: 1 ether}();
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.redeem(shares, bob, bob);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.shortfallReserve(), 1 ether);
        assertEq(pool.unvestedDonations(), 0);
        assertEq(pool.totalAssets(), 0);
        pool.depositETH{value: 1 ether}(buyer);
        pool.donate{value: 2 ether}(); // Same timestamp as the retired checkpoint.
        assertEq(pool.unvestedDonations(), 2 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pool.totalAssets(), 3 ether);
        assertEq(pool.shortfallReserve(), 1 ether);
    }

    function test_roundingAllowsAllBackedAssetsToExit() public {
        LendingPool p = new LendingPool(owner, address(weth), address(this));
        p.depositETH{value: 1 ether}(bob);
        p.borrow(1 ether);
        p.settle{value: 0.15 ether}(1 ether);
        uint256 limit = p.maxWithdraw(bob);
        assertEq(limit, p.previewRedeem(p.balanceOf(bob)));
        uint256 shares = p.maxRedeem(bob);
        vm.prank(bob);
        p.redeem(shares, bob, bob);
        // Improved maxRedeem can return all shares on the first call. If a wei remains,
        // it must be advertised and withdrawable; the original double-floor bug is gone.
        uint256 remaining = p.previewRedeem(p.balanceOf(bob));
        assertEq(p.maxWithdraw(bob), remaining);
        if (remaining != 0) {
            vm.prank(bob);
            p.withdrawETH(remaining, bob, bob);
        }
        assertEq(p.maxWithdraw(bob), 0);
        assertEq(weth.balanceOf(bob) + p.claimable(bob), limit);
    }

    function testFuzz_maxRedeemNeverExceedsIdle(uint256 principal, uint256 recovered) public {
        principal = bound(principal, 1, 5 ether);
        recovered = bound(recovered, 0, principal);
        LendingPool p = new LendingPool(owner, address(weth), address(this));
        p.depositETH{value: 5 ether}(bob);
        p.borrow(principal);
        p.settle{value: recovered}(principal);
        p.borrow(p.idleAssets() / 2);
        uint256 shares = p.maxRedeem(bob);
        uint256 idle = p.idleAssets();
        assertLe(p.previewRedeem(shares), idle);
        if (shares < p.balanceOf(bob)) assertGt(p.previewRedeem(shares + 1), idle);
        uint256 assets = p.maxWithdraw(bob);
        if (assets > 0) {
            vm.prank(bob);
            p.withdrawETH(assets, bob, bob);
            assertEq(p.claimable(bob), assets);
        }
    }

    function test_oneWeiEntitlementAfterPartialRedemptionRemainsWithdrawable() public {
        LendingPool p = new LendingPool(owner, address(weth), address(this));
        p.depositETH{value: 1 ether}(bob);
        p.borrow(1 ether);
        p.settle{value: 0.15 ether}(1 ether);
        uint256 shares = p.convertToShares(p.idleAssets());
        vm.prank(bob);
        p.redeem(shares, bob, bob);
        assertEq(p.idleAssets(), 1);
        assertEq(p.previewRedeem(p.balanceOf(bob)), 1);
        assertEq(p.maxWithdraw(bob), 1);
        vm.prank(bob);
        p.withdrawETH(1, bob, bob);
        assertEq(p.claimable(bob), 1);
        assertEq(p.idleAssets(), 0);
    }

    receive() external payable {}
}
