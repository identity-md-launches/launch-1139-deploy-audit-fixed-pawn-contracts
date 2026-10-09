// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @notice Revision additions: edges the accepted suites leave implicit. The overdue mark's monotonicity
/// against a moving floor, a re-queued identical governance change, a disabled collection's open loans,
/// the ERC-4626 token paths' own limit errors, and a fork check of the live PAWN token that skips offline.
contract RevisionEdgesTest is PawnTestBase {
    address constant PAWN_TOKEN = 0x4F2BACEE5f2e7cE3F48DFbd635d96E9A8FcbE478;

    function _floorLater(uint256 price) private {
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(price);
    }

    // ---------------------------------------------------------------- overdue mark against a moving floor

    /// @dev markOverdue may be repeated by anyone. A falling floor raises the mark; a rising floor is refused
    /// rather than lowering it, because only a call that reports held collateral may lower a mark. The
    /// auction start (with the token held) and a borrower's extension are the two paths that lower it.
    function test_markOverdueNeverLowersTheMarkButAuctionAndExtensionDo() public {
        uint256 first = _pawn(1, 0);
        uint256 second = _pawn(2, 0);
        vm.warp(shop.getLoan(first).due - 1);
        _floor(0.5 ether);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markOverdue(999); // unknown loans are not active
        vm.expectRevert(PawnShop.NotOverdue.selector);
        shop.markOverdue(first); // one second before the due date is still current
        vm.warp(vm.getBlockTimestamp() + 1);
        shop.markOverdue(first);
        shop.markOverdue(second);
        assertEq(pool.auctionLoss(first), 0.15 ether, "0.4 principal less half of a 0.5 floor");
        assertEq(pool.expectedAuctionLoss(), 0.3 ether);
        uint256 bookBefore = pool.totalAssets();

        // The floor recovers: the mark stays where it is and the call is refused outright.
        _floorLater(1 ether);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        shop.markOverdue(first);
        assertEq(pool.auctionLoss(first), 0.15 ether);
        assertEq(pool.totalAssets(), bookBefore, "a refused mark changes nothing");

        // The floor falls further: the mark follows it upward and the book falls by the difference.
        _floorLater(0.4 ether);
        shop.markOverdue(first);
        assertEq(pool.auctionLoss(first), 0.2 ether);
        assertEq(pool.expectedAuctionLoss(), 0.35 ether);
        assertEq(pool.totalAssets(), bookBefore - 0.05 ether);
        // Repeating the same mark at the same floor is an idempotent no-op.
        shop.markOverdue(first);
        assertEq(pool.auctionLoss(first), 0.2 ether);
        assertEq(pool.totalAssets(), bookBefore - 0.05 ether);

        // The borrower extends the second loan: its mark is released through the vesting stream.
        uint256 fee = 0.012 ether;
        vm.prank(alice);
        shop.extend{value: fee}(second, 0);
        assertEq(pool.auctionLoss(second), 0);
        assertEq(pool.expectedAuctionLoss(), 0.2 ether);
        assertGe(pool.unvestedRelease(), 0.15 ether - 1, "the released mark is not recognised at once");

        // The auction opens on a recovered floor with the token held: the mark may now fall to zero.
        vm.warp(shop.getLoan(first).due + shop.GRACE() + 1);
        _floor(1 ether);
        shop.startAuction(first);
        assertEq(pool.auctionLoss(first), 0, "a full-floor opening price covers the principal");
        assertEq(pool.expectedAuctionLoss(), 0);
        // Once in auction, the public mark refresh can only follow the curve, never the overdue path.
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markOverdue(first);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        shop.markAuctionLoss(first);
        assertEq(pool.auctionLoss(first), 0, "half of a 1 ETH floor still covers 0.4");
    }

    // ---------------------------------------------------------------- governance: identical re-queue

    /// @dev Queueing the very same change again cancels the pending copy and restarts its 48-hour clock, so
    /// the first clock can never be used to execute early; the owner cannot shorten a delay by repetition.
    function test_requeueingTheSameChangeRestartsItsClock() public {
        uint256 t0 = vm.getBlockTimestamp();
        bytes32 op = keccak256(abi.encode("term", uint8(0), uint32(60 days), uint16(300)));
        vm.prank(owner);
        shop.queueTerm(0, 60 days, 300);
        assertEq(shop.queuedAt(op), t0 + shop.DELAY());

        vm.warp(t0 + 24 hours);
        vm.prank(owner);
        shop.queueTerm(0, 60 days, 300);
        assertEq(shop.queuedAt(op), t0 + 24 hours + shop.DELAY(), "the clock restarts");

        vm.warp(t0 + shop.DELAY());
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeTerm(0, 60 days, 300);
        (uint32 duration,) = shop.terms(0);
        assertEq(duration, 30 days, "the term is untouched until the restarted clock runs out");

        vm.warp(t0 + 24 hours + shop.DELAY());
        shop.executeTerm(0, 60 days, 300);
        (duration,) = shop.terms(0);
        assertEq(duration, 60 days);
        // Executed once; the same arguments cannot be replayed without a new queue entry.
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeTerm(0, 60 days, 300);
        assertEq(shop.queuedAt(op), 0);

        // Cancelling an operation that was never queued is harmless and leaves other queues alone.
        vm.prank(owner);
        shop.queueFeeRecipient(alice);
        vm.prank(owner);
        shop.cancelChange(keccak256("nothing"));
        assertEq(shop.queuedAt(keccak256(abi.encode("recipient", alice))), vm.getBlockTimestamp() + shop.DELAY());
    }

    // ---------------------------------------------------------------- disabled collection: open loans

    /// @dev Disabling a collection stops new loans immediately, but every open loan must still be
    /// extendable, repayable and auctionable: a borrower or lender can never be trapped by the switch.
    function test_disabledCollectionStillSettlesExistingLoans() public {
        uint256 first = _pawn(1, 0);
        uint256 second = _pawn(2, 1);
        vm.prank(owner);
        shop.disableCollection(address(nft));
        (,,,, bool enabled,) = shop.collections(address(nft));
        assertFalse(enabled);

        nft.mint(alice, 3);
        vm.startPrank(alice);
        nft.approve(address(shop), 3);
        vm.expectRevert(PawnShop.CollectionDisabled.selector);
        shop.pawn(address(nft), 3, 0, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(nft.ownerOf(3), alice);

        // Floors may still be posted for the disabled collection, and extensions still price on them.
        _floorLater(1 ether);
        uint256 dueBefore = shop.getLoan(first).due;
        vm.prank(alice);
        shop.extend{value: 0.004 ether}(first, 1);
        assertEq(shop.getLoan(first).due, dueBefore + 7 days);
        shop.repay{value: 0.4 ether}(first);
        assertEq(nft.ownerOf(1), alice);
        assertEq(shop.collectionDebt(address(nft)), 0.4 ether);

        // The second loan defaults and is auctioned and bought while the collection stays disabled.
        vm.warp(shop.getLoan(second).due);
        shop.markOverdue(second);
        vm.warp(shop.getLoan(second).due + shop.GRACE() + 1);
        _refreshFloor();
        shop.startAuction(second);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(second);
        vm.prank(buyer);
        shop.buyAuction{value: price}(second, buyer);
        assertEq(nft.ownerOf(2), buyer);
        assertEq(shop.collectionDebt(address(nft)), 0);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(pool.expectedAuctionLoss(), 0);
        // Still disabled afterwards: no loan slipped through the settlement path.
        (,,,, enabled,) = shop.collections(address(nft));
        assertFalse(enabled);
        assertEq(shop.nextLoanId(), 3);
    }

    // ---------------------------------------------------------------- ERC-4626 token paths

    /// @dev The WETH (ERC-20) entry and exit paths are bounded by the same cap and idle liquidity as the
    /// native ones, through the standard ERC-4626 limit errors, and refuse a zero receiver.
    function test_erc20PathsRefuseZeroReceiverCapAndIdleLimits() public {
        vm.startPrank(buyer);
        weth.deposit{value: 20 ether}();
        weth.approve(address(pool), type(uint256).max);
        uint256 room = pool.maxDeposit(buyer);
        assertEq(room, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, buyer, room + 1, room));
        pool.deposit(room + 1, buyer);
        uint256 shareRoom = pool.maxMint(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, buyer, shareRoom + 1, shareRoom)
        );
        pool.mint(shareRoom + 1, buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        pool.deposit(1 ether, address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        pool.depositETH{value: 1 ether}(address(0));
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.deposit(0, buyer);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.mint(0, buyer);
        // Exactly the cap, in shares, fills it to zero room.
        uint256 paid = pool.mint(shareRoom, buyer);
        assertLe(paid, room);
        assertEq(pool.maxDeposit(buyer), room - paid);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(pool)), 5 ether + paid);

        // A loan takes 0.4 of the idle cash; the lender fee share vests and is not idle yet.
        uint256 id = _pawn(1, 0);
        assertEq(pool.idleAssets(), 5 ether + paid - 0.4 ether);
        uint256 limit = pool.maxWithdraw(bob);
        uint256 shares = pool.maxRedeem(bob);
        assertEq(limit, pool.previewRedeem(pool.balanceOf(bob)), "bob's whole stake fits in idle cash");
        assertEq(shares, pool.balanceOf(bob));
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, bob, limit + 1, limit));
        pool.withdraw(limit + 1, bob, bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, bob, shares + 1, shares));
        pool.redeem(shares + 1, bob, bob);
        vm.stopPrank();

        // Buyer withdraws everything that is idle after bob, so bob's exit is bounded by idle cash, not stake.
        vm.prank(bob);
        pool.withdraw(limit, bob, bob);
        assertEq(weth.balanceOf(bob), limit);
        uint256 idle = pool.idleAssets();
        uint256 buyerLimit = pool.maxWithdraw(buyer);
        assertEq(buyerLimit, idle, "only idle cash can leave while principal is lent");
        assertLt(buyerLimit, pool.previewRedeem(pool.balanceOf(buyer)));
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, buyer, buyerLimit + 1, buyerLimit)
        );
        pool.withdraw(buyerLimit + 1, buyer, buyer);
        uint256 maxShares = pool.maxRedeem(buyer);
        assertLe(pool.previewRedeem(maxShares), idle);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, buyer, maxShares + 1, maxShares)
        );
        pool.redeem(maxShares + 1, buyer, buyer);
        pool.withdraw(buyerLimit, buyer, buyer);
        vm.stopPrank();
        assertEq(pool.idleAssets(), 0);
        assertGt(pool.balanceOf(buyer), 0, "the lent principal still backs the remaining shares");
        // Repayment makes the remainder redeemable again.
        shop.repay{value: 0.4 ether}(id);
        assertEq(pool.maxRedeem(buyer), pool.balanceOf(buyer));
    }

    // ---------------------------------------------------------------- live dependency (fork, skips offline)

    /// @dev The launch binds the shop to the PAWN token already on mainnet. Its runtime code must be the
    /// LaunchToken this suite tests, so the exact-transfer semantics LockDiscount and MilestoneBurn assume
    /// are the ones covered offline. Runs only when PAWN_MAINNET_RPC_URL is set; the verifier has no network.
    function testFork_livePawnTokenIsTheLaunchTokenAndTransfersExactly() public {
        string memory url = vm.envOr("PAWN_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(keccak256(PAWN_TOKEN.code), keccak256(type(LaunchToken).runtimeCode), "live PAWN is LaunchToken");
        LaunchToken live = LaunchToken(PAWN_TOKEN);
        assertEq(live.decimals(), 18);
        assertEq(live.totalSupply(), 1_000_000_000 ether);
        deal(PAWN_TOKEN, alice, 1_000_000 ether);
        vm.prank(alice);
        live.transfer(bob, 1_000_000 ether);
        assertEq(live.balanceOf(bob), 1_000_000 ether, "no fee on transfer");
        assertEq(live.balanceOf(alice), 0);
    }

    receive() external payable {}
}
