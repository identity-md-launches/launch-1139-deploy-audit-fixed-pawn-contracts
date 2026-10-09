// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {LockDiscount} from "../src/LockDiscount.sol";

/// @notice Stateless properties over the arithmetic edges: the auction curve, donation vesting, entry pricing
/// during a release stream and the lock tiers. Known edge values are pinned as plain assertions beside them.
contract PropertyFuzzTest is PawnTestBase {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_auctionCurveEndpointsJoinAndRoundingFavourThePool(uint256 auctionFloor, uint256 elapsed) public {
        auctionFloor = bound(auctionFloor, 1, 1_000_000 ether);
        elapsed = bound(elapsed, 0, 30 days);
        uint256 id = _pawn(1, 1);
        vm.warp(shop.getLoan(id).due + 3 days + 1);
        _floor(auctionFloor);
        shop.startAuction(id);
        uint256 start = vm.getBlockTimestamp();
        assertEq(shop.auctionPrice(id), auctionFloor, "starts at the full floor");
        vm.warp(start + 3 days);
        uint256 atThreeDays = shop.auctionPrice(id);
        assertEq(atThreeDays, Math.ceilDiv(auctionFloor * 7, 10));
        vm.warp(start + 3 days + 1);
        uint256 justAfter = shop.auctionPrice(id);
        assertLe(justAfter, atThreeDays);
        assertLe(atThreeDays - justAfter, auctionFloor / 3_024_000 + 2, "the slopes join continuously");
        vm.warp(start + 10 days - 1);
        assertGe(shop.auctionPrice(id), Math.ceilDiv(auctionFloor, 2));
        vm.warp(start + 10 days);
        assertEq(shop.auctionPrice(id), Math.ceilDiv(auctionFloor, 2), "terminal price is half, rounded up");

        vm.warp(start + elapsed);
        uint256 price = shop.auctionPrice(id);
        assertGe(price, Math.ceilDiv(auctionFloor, 2));
        assertLe(price, auctionFloor);
        // Specification: the rational curve rounded up, so the price is never below the real-number value
        // and never more than one wei above it.
        uint256 numerator;
        uint256 denominator;
        if (elapsed <= 3 days) {
            numerator = 10000 * 3 days - 3000 * elapsed;
            denominator = 10000 * 3 days;
        } else if (elapsed < 10 days) {
            numerator = 7000 * 7 days - 2000 * (elapsed - 3 days);
            denominator = 10000 * 7 days;
        } else {
            numerator = 5000;
            denominator = 10000;
        }
        assertGe(price * denominator, auctionFloor * numerator);
        assertLt((price - 1) * denominator, auctionFloor * numerator);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_donationStreamsAreBoundedMonotoneAndCompleteInSevenDays(
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 g1,
        uint256 g2,
        uint256 probe
    ) public {
        a1 = bound(a1, 1, 10 ether);
        a2 = bound(a2, 1, 10 ether);
        a3 = bound(a3, 1, 10 ether);
        g1 = bound(g1, 0, 8 days);
        g2 = bound(g2, 0, 8 days);
        probe = bound(probe, 0, 8 days);
        uint256 base = pool.totalAssets();
        pool.donate{value: a1}();
        vm.warp(vm.getBlockTimestamp() + g1);
        pool.donate{value: a2}();
        vm.warp(vm.getBlockTimestamp() + g2);
        pool.donate{value: a3}();
        uint256 total = a1 + a2 + a3;
        uint256 unvested = pool.unvestedDonations();
        assertLe(unvested, total);
        assertGe(unvested, a3, "the newest tranche is wholly unvested at its start");
        assertEq(pool.totalAssets() + unvested, base + total, "every donated wei is vested or unvested");
        vm.warp(vm.getBlockTimestamp() + probe);
        uint256 later = pool.unvestedDonations();
        assertLe(later, unvested, "vesting never reverses");
        assertEq(pool.totalAssets() + later, base + total);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertEq(pool.unvestedDonations(), 0);
        assertEq(pool.totalAssets(), base + total);
        assertEq(pool.cumulativeDonations(), total);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_entryDuringReleaseStreamNeverGainsOnImmediateExit(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 0.001 ether, 4 ether);
        elapsed = bound(elapsed, 0, 8 days);
        uint256 id = _pawn(1, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(0.5 ether);
        vm.warp(shop.getLoan(id).due);
        shop.markOverdue(id); // books 0.4 - 0.25 = 0.15 against half the stored floor
        shop.repay{value: 0.4 ether}(id); // realised loss zero: the 0.15 allowance vests over seven days
        assertApproxEqAbs(pool.unvestedRelease(), 0.15 ether, 1);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 bobBefore = pool.previewRedeem(pool.balanceOf(bob));
        vm.startPrank(buyer);
        uint256 shares = pool.depositETH{value: amount}(buyer);
        uint256 assets = pool.redeemETH(shares, buyer, buyer);
        vm.stopPrank();
        assertLe(assets, amount, "an immediate round trip never extracts value");
        assertGe(pool.previewRedeem(pool.balanceOf(bob)), bobBefore, "existing lenders are never diluted");
        if (elapsed >= 7 days) assertApproxEqAbs(assets, amount, 2, "without a stream only rounding is lost");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_lockedTokensAreFullyAccountedAndTiersAreMonotone(uint256 first, uint256 second) public {
        first = bound(first, 1, 30_000_000 ether);
        second = bound(second, 1, 30_000_000 ether);
        _lock(first);
        uint8 t1 = discount.tierOf(alice);
        _lock(second);
        uint8 t2 = discount.tierOf(alice);
        uint256 total = first + second;
        assertGe(t2, t1);
        assertEq(discount.locked(alice), total);
        assertEq(token.balanceOf(address(discount)), total, "custody equals the ledger");
        assertGe(total, discount.tierAmount(t2));
        if (t2 < 3) assertLt(total, discount.tierAmount(t2 + 1));
        // A commitment pins exactly the current tier's amount; the rest stays free, and not a wei more.
        vm.prank(address(shop));
        discount.commit(7, alice, 1 ether);
        assertEq(discount.committed(alice), discount.tierAmount(t2));
        uint256 free = discount.unlockable(alice);
        assertEq(free, total - discount.tierAmount(t2));
        if (free != 0) {
            vm.prank(alice);
            discount.unlock(free);
        }
        assertEq(discount.locked(alice), discount.tierAmount(t2));
        vm.prank(alice);
        vm.expectRevert(LockDiscount.Committed.selector);
        discount.unlock(1);
        assertEq(discount.tierOf(alice), t2, "the committed amount keeps the tier");
        vm.prank(address(shop));
        discount.release(7);
        assertEq(discount.unlockable(alice), discount.locked(alice));
    }

    receive() external payable {}
}
