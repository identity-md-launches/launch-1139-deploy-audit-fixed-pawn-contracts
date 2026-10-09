// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LockDiscount} from "../src/LockDiscount.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MilestoneBurn} from "../src/MilestoneBurn.sol";
import {PullPayments} from "../src/PullPayments.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

/// @notice Failure paths and exact boundaries the accepted suites leave implicit: every loan-state
/// transition that must be refused, exact-equality limits, and input guards on all five contracts.
contract FailurePathsTest is PawnTestBase {
    // ---------------------------------------------------------------- PawnShop: loan state machine

    function test_pawnRejectsBadTermUnknownCollectionAndPause() public {
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.approve(address(shop), 1);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.pawn(address(nft), 1, 2, 0, type(uint256).max);
        vm.expectRevert(PawnShop.CollectionDisabled.selector);
        shop.pawn(address(token), 1, 0, 0, type(uint256).max);
        vm.stopPrank();
        vm.prank(owner);
        shop.setNewLoansPaused(true);
        vm.prank(alice);
        vm.expectRevert(PawnShop.Paused.selector);
        shop.pawn(address(nft), 1, 0, 0, type(uint256).max);
        assertEq(nft.ownerOf(1), alice);
        assertEq(shop.nextLoanId(), 1);
    }

    /// @dev With a 5 ETH pool and a 100% share cap, ten 0.5 ETH loans fill the cap exactly; the eleventh fails
    /// on the share check before any vault is created or collateral moves.
    function test_shareCapAndIdleLiquidityAreExactAtTheBoundary() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        _floor(1.25 ether);
        for (uint256 i = 1; i <= 10; ++i) {
            _pawn(i, 0);
        }
        assertEq(shop.collectionDebt(address(nft)), 5 ether);
        assertEq(pool.idleAssets(), 0);
        assertEq(pool.totalAssets(), 5 ether);
        uint256 nextId = shop.nextLoanId();
        nft.mint(alice, 11);
        vm.startPrank(alice);
        nft.approve(address(shop), 11);
        vm.expectRevert(PawnShop.ShareExceeded.selector);
        shop.pawn(address(nft), 11, 0, 0, type(uint256).max);
        vm.stopPrank();
        assertEq(shop.nextLoanId(), nextId);
        assertEq(nft.ownerOf(11), alice);
        // Repaying one loan reopens exactly one slot.
        shop.repay{value: 0.5 ether}(1);
        vm.prank(alice);
        shop.pawn(address(nft), 11, 0, 0, type(uint256).max);
        assertEq(shop.collectionDebt(address(nft)), 5 ether);
    }

    function test_repaidLoanRefusesEveryLaterAction() public {
        uint256 id = _pawn(1, 0);
        vm.prank(alice);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.extend{value: 0.012 ether}(id, 2);
        shop.repay{value: 0.4 ether}(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.repay{value: 0.4 ether}(id);
        vm.prank(alice);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.extend{value: 0.012 ether}(id, 0);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markOverdue(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.startAuction(id);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.auctionPrice(id);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.buyAuction{value: 1 ether}(id, buyer);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.markAuctionLoss(id);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.restartAuction(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(id);
        // The released vault cannot be released twice, by the shop or anyone else.
        CollateralVault vault = CollateralVault(payable(shop.getLoan(id).vault));
        vm.prank(address(shop));
        vm.expectRevert(CollateralVault.InactiveLoan.selector);
        vault.release(alice);
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.release(alice);
        // Unknown loan ids are refused the same way.
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.repay{value: 0}(999);
        assertEq(uint256(shop.getLoan(id).status), uint256(PawnShop.Status.Repaid));
    }

    function test_graceBoundaryAndAuctionStateRefusals() public {
        uint256 id = _pawn(1, 1);
        uint256 due = shop.getLoan(id).due;
        vm.warp(due + shop.GRACE());
        _refreshFloor();
        vm.expectRevert(PawnShop.GracePeriod.selector);
        shop.startAuction(id);
        vm.warp(due + shop.GRACE() + 1);
        shop.startAuction(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.startAuction(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.repay{value: 0.4 ether}(id);
        vm.prank(alice);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.extend{value: 0.004 ether}(id, 1);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.markOverdue(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 price = shop.auctionPrice(id);
        shop.buyAuction{value: price}(id, buyer);
        assertEq(uint256(shop.getLoan(id).status), uint256(PawnShop.Status.Sold));
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.buyAuction{value: price}(id, buyer);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.writeOffAuction(id);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.restartAuction(id);
        vm.expectRevert(PawnShop.NotAuctioning.selector);
        shop.markAuctionLoss(id);
        vm.expectRevert(PawnShop.InvalidLoan.selector);
        shop.repay{value: 0.4 ether}(id);
    }

    // ---------------------------------------------------------------- PawnShop: floor freshness

    function test_floorFreshnessIsInclusiveAtTwentySixHours() public {
        (, uint64 issuedAt,,) = shop.floors(address(nft));
        vm.warp(uint256(issuedAt) + shop.FLOOR_MAX_AGE());
        assertTrue(shop.floorFresh(address(nft)));
        vm.warp(uint256(issuedAt) + shop.FLOOR_MAX_AGE() + 1);
        assertFalse(shop.floorFresh(address(nft)));
        nft.mint(alice, 1);
        vm.startPrank(alice);
        nft.approve(address(shop), 1);
        vm.expectRevert(PawnShop.StaleFloor.selector);
        shop.pawn(address(nft), 1, 0, 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_submitFloorAgeAndTimeBoundaries() public {
        (, uint64 storedIssuedAt,,) = shop.floors(address(nft));
        vm.warp(uint256(storedIssuedAt) + shop.FLOOR_MAX_AGE() + 2);
        uint256 now_ = vm.getBlockTimestamp();
        // Exactly FLOOR_MAX_AGE old is still accepted and immediately fresh for one more second.
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 2 ether);
        a.issuedAt = uint64(now_ - shop.FLOOR_MAX_AGE());
        a.expiresAt = uint64(now_ + 1);
        shop.submitFloor(address(nft), a, _signature(shop, a));
        assertTrue(shop.floorFresh(address(nft)));
        (uint256 price,, uint64 expiresAt,) = shop.floors(address(nft));
        assertEq(price, 2 ether);
        assertEq(expiresAt, now_ + 1);
        // One second older is refused.
        a = _attestation(FLOOR_QUESTION, 3 ether);
        a.issuedAt = uint64(now_ - shop.FLOOR_MAX_AGE() - 1);
        a.expiresAt = uint64(now_ + 1);
        bytes memory sig = _signature(shop, a);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        // A future issue time is refused by the shop even inside the consumer's five-minute tolerance.
        a = _attestation(FLOOR_QUESTION, 3 ether);
        a.issuedAt = uint64(now_ + 1);
        sig = _signature(shop, a);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        // Expiry must follow issue time.
        a = _attestation(FLOOR_QUESTION, 3 ether);
        a.expiresAt = a.issuedAt;
        sig = _signature(shop, a);
        vm.expectRevert(PawnShop.InvalidAttestation.selector);
        shop.submitFloor(address(nft), a, sig);
        // A collection without a question cannot receive floors at all.
        a = _attestation(FLOOR_QUESTION, 3 ether);
        sig = _signature(shop, a);
        vm.expectRevert(PawnShop.NotConfigured.selector);
        shop.submitFloor(address(token), a, sig);
        (price,,,) = shop.floors(address(nft));
        assertEq(price, 2 ether);
    }

    function test_bountyShortfallSkipsPaymentWithoutBlockingTheUpdate() public {
        shop.fundBounties{value: shop.FLOOR_BOUNTY() - 1}();
        vm.warp(vm.getBlockTimestamp() + shop.FLOOR_BOUNTY_INTERVAL());
        uint256 before = shop.claimable(buyer);
        OracleAttestation.Attestation memory a = _attestation(FLOOR_QUESTION, 1.5 ether);
        bytes memory sig = _signature(shop, a);
        vm.prank(buyer);
        shop.submitFloor(address(nft), a, sig);
        (uint256 price,,, uint64 lastBountyAt) = shop.floors(address(nft));
        assertEq(price, 1.5 ether);
        assertEq(lastBountyAt, vm.getBlockTimestamp(), "the interval is consumed even when unpaid");
        assertEq(shop.claimable(buyer), before);
        assertEq(shop.bountyReserve(), shop.FLOOR_BOUNTY() - 1);
        // Topping up by one wei makes the next eligible update pay in full.
        shop.fundBounties{value: 1}();
        vm.warp(vm.getBlockTimestamp() + shop.FLOOR_BOUNTY_INTERVAL());
        a = _attestation(FLOOR_QUESTION, 1.6 ether);
        sig = _signature(shop, a);
        vm.prank(buyer);
        shop.submitFloor(address(nft), a, sig);
        assertEq(shop.claimable(buyer) - before, shop.FLOOR_BOUNTY());
        assertEq(shop.bountyReserve(), 0);
    }

    // ---------------------------------------------------------------- PawnShop: governance inputs

    function test_governanceInputGuards() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        shop.setNewLoansPaused(false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        shop.cancelChange(bytes32(0));

        vm.startPrank(owner);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.queueTerm(2, 30 days, 300);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.queueTerm(0, 7 days - 1, 300);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.queueTerm(0, 90 days + 1, 300);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.queueTerm(0, 30 days, 49);
        vm.expectRevert(PawnShop.InvalidTerm.selector);
        shop.queueTerm(0, 30 days, 1001);
        shop.queueTerm(0, 7 days, 50);
        shop.queueTerm(1, 90 days, 1000);

        PawnShop.Collection memory c = PawnShop.Collection(4000, 4000, 2500, false, true, bytes32(0));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(0), c);
        c.maxLoanBps0 = 4001;
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(token), c);
        c.maxLoanBps0 = 4000;
        c.maxLoanBps1 = 4001;
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(token), c);
        c.maxLoanBps1 = 4000;
        c.maxShareBps = 2501; // a non-seat collection may not take more than a quarter of the pool
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(token), c);
        c.isSeat = true;
        c.maxShareBps = 10001;
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(token), c);
        // The governed identity question can never rotate back to the unset, one-shot state.
        c.maxShareBps = 10000;
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueCollection(address(nft), c);

        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.setQuestionHashOnce(address(nft), keccak256("again"));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.setQuestionHashOnce(address(token), keccak256("unknown collection"));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.approveQuestionHash(address(token), keccak256("unknown collection"));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.approveQuestionHash(address(nft), bytes32(0));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueAttester(address(0));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueFeeRecipient(address(0));
        vm.stopPrank();

        // Nothing executes without a matching queue entry.
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeTerm(0, 30 days, 300);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeAttester(alice);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeFeeRecipient(alice);
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeDiscountModule(address(discount));
    }

    function test_collectionWithoutCodeAndForeignModulesAreRefusedAtExecution() public {
        address eoaCollection = makeAddr("eoa collection");
        PawnShop.Collection memory c = PawnShop.Collection(4000, 4000, 10000, true, true, keccak256("q"));
        vm.prank(owner);
        shop.queueCollection(eoaCollection, c);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.executeCollection(eoaCollection, c);
        (,, uint16 share,,,) = shop.collections(eoaCollection);
        assertEq(share, 0);

        LockDiscount otherShop = new LockDiscount(address(token), alice);
        LockDiscount otherToken = new LockDiscount(address(weth), address(shop));
        vm.startPrank(owner);
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueDiscountModule(makeAddr("eoa module"));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueDiscountModule(address(otherShop));
        vm.expectRevert(PawnShop.InvalidConfiguration.selector);
        shop.queueDiscountModule(address(otherToken));
        // A spare module bound to this shop and token (the manifest's separately deployed LockDiscount) is
        // accepted, but only after the 48-hour delay; until then the constructor-created module stays active.
        LockDiscount spare = new LockDiscount(address(token), address(shop));
        shop.queueDiscountModule(address(spare));
        vm.stopPrank();
        vm.expectRevert(PawnShop.TimelockPending.selector);
        shop.executeDiscountModule(address(spare));
        assertEq(shop.discountModule(), address(discount));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        shop.executeDiscountModule(address(spare));
        assertEq(shop.discountModule(), address(spare));
    }

    // ---------------------------------------------------------------- LendingPool

    function test_poolInputGuardsAndAccess() public {
        uint256 shares = pool.balanceOf(bob);
        uint256 room = pool.maxDeposit(buyer);
        assertEq(room, 5 ether);
        vm.startPrank(buyer);
        vm.expectRevert(LendingPool.CapExceeded.selector);
        pool.depositETH{value: room + 1}(buyer);
        pool.depositETH{value: room}(buyer);
        assertEq(pool.maxDeposit(buyer), 0);
        vm.expectRevert(LendingPool.CapExceeded.selector);
        pool.depositETH{value: 1}(buyer);
        vm.stopPrank();

        uint256 limit = pool.maxWithdraw(bob);
        vm.startPrank(bob);
        vm.expectRevert(LendingPool.InsufficientIdle.selector);
        pool.withdrawETH(limit + 1, bob, bob);
        vm.expectRevert(LendingPool.InsufficientIdle.selector);
        pool.redeemETH(shares + 1, bob, bob);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        pool.redeemETH(shares, address(0), bob);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        pool.withdrawETH(1 ether, address(0), bob);
        vm.stopPrank();
        assertEq(pool.balanceOf(bob), shares);

        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.donate{value: 0}();
        vm.deal(address(this), uint256(type(uint128).max) + 1 ether);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.donate{value: uint256(type(uint128).max) + 1}();
        pool.donate{value: type(uint128).max}();
        assertEq(pool.unvestedDonations(), type(uint128).max);

        uint256 cap = pool.depositCap();
        vm.startPrank(owner);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.queueDepositCap(cap);
        vm.expectRevert(LendingPool.TimelockPending.selector);
        pool.cancelDepositCap();
        vm.stopPrank();
        vm.expectRevert(LendingPool.TimelockPending.selector);
        pool.executeDepositCap();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.queueDepositCap(20 ether);

        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.borrow(1);
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.addReserve{value: 1}();
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.receiveFee{value: 1}();
        vm.expectRevert(LendingPool.OnlyPawnShop.selector);
        pool.settle{value: 0}(0);
        vm.deal(address(shop), 1 ether);
        uint256 idle = pool.idleAssets();
        vm.startPrank(address(shop));
        vm.expectRevert(LendingPool.InsufficientIdle.selector);
        pool.borrow(idle + 1);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.markAuctionLoss(1, 1, 0, false);
        vm.expectRevert(LendingPool.InvalidAmount.selector);
        pool.settle{value: 0}(1);
        vm.stopPrank();
        assertEq(pool.totalBorrowed(), 0);

        vm.prank(owner);
        vm.expectRevert(LendingPool.RenounceDisabled.selector);
        pool.renounceOwnership();
        vm.prank(owner);
        pool.transferOwnership(alice);
        assertEq(pool.owner(), owner);
        assertEq(pool.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        pool.acceptOwnership();
        vm.prank(alice);
        pool.acceptOwnership();
        assertEq(pool.owner(), alice);
    }

    function test_thirdPartyNativeRedemptionNeedsShareAllowance() public {
        uint256 shares = pool.balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, shares));
        pool.redeemETH(shares, alice, bob);
        vm.prank(bob);
        pool.approve(alice, shares - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, shares - 1, shares)
        );
        pool.redeemETH(shares, alice, bob);
        vm.prank(alice);
        uint256 assets = pool.redeemETH(shares - 1, alice, bob);
        assertEq(pool.claimable(alice), assets);
        assertEq(pool.allowance(bob, alice), 0);
        assertEq(pool.balanceOf(bob), 1);
    }

    // ---------------------------------------------------------------- CollateralVault

    function test_vaultInitializationAndReceiverGuards() public {
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        new CollateralVault(address(0));
        vm.expectRevert(VaultFactory.Unauthorized.selector);
        shop.vaultFactory().create();

        uint256 id = _pawn(1, 0);
        CollateralVault vault = CollateralVault(payable(shop.getLoan(id).vault));
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.initialize(alice, address(nft), 1, id, address(pool), true);
        vm.prank(address(shop));
        vm.expectRevert(CollateralVault.AlreadyInitialized.selector);
        vault.initialize(alice, address(nft), 1, id, address(pool), true);

        vm.prank(address(shop));
        CollateralVault fresh = CollateralVault(payable(shop.vaultFactory().create()));
        assertEq(fresh.pawnShop(), address(shop));
        vm.startPrank(address(shop));
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        fresh.initialize(address(0), address(nft), 2, 2, address(pool), true);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        fresh.initialize(alice, address(0), 2, 2, address(pool), true);
        vm.expectRevert(PullPayments.InvalidRecipient.selector);
        fresh.initialize(alice, address(nft), 2, 2, address(0), true);
        vm.stopPrank();
        // An uninitialized vault accepts no NFT at all.
        vm.prank(address(nft));
        vm.expectRevert(CollateralVault.UnexpectedNFT.selector);
        fresh.onERC721Received(address(shop), alice, 2, "");

        // The initialized vault accepts only its own token, sent by its collection, operated by the shop.
        vm.expectRevert(CollateralVault.UnexpectedNFT.selector);
        vault.onERC721Received(address(shop), alice, 1, "");
        vm.startPrank(address(nft));
        vm.expectRevert(CollateralVault.UnexpectedNFT.selector);
        vault.onERC721Received(alice, alice, 1, "");
        vm.expectRevert(CollateralVault.UnexpectedNFT.selector);
        vault.onERC721Received(address(shop), alice, 2, "");
        assertEq(vault.onERC721Received(address(shop), alice, 1, ""), IERC721Receiver.onERC721Received.selector);
        vm.stopPrank();
        // A stray NFT of the same collection pushed with the safe path is bounced.
        nft.mint(buyer, 3);
        vm.prank(buyer);
        vm.expectRevert(CollateralVault.UnexpectedNFT.selector);
        nft.safeTransferFrom(buyer, address(vault), 3);
    }

    /// @dev A fresh struct each time: memory structs are references, so mutating a copy would mutate `m`.
    function _auth(CollateralVault vault) private view returns (CollateralVault.WorkerAuthorization memory) {
        return CollateralVault.WorkerAuthorization(
            keccak256("device"),
            address(vault),
            1,
            keccak256("nonce"),
            uint64(vm.getBlockTimestamp() + 1),
            "https://api.imd.fun"
        );
    }

    function test_vaultBorrowerOnlyActionsAndTheirInputs() public {
        uint256 id = _pawn(1, 0);
        CollateralVault vault = CollateralVault(payable(shop.getLoan(id).vault));
        CollateralVault.WorkerAuthorization memory m = _auth(vault);
        vm.startPrank(buyer);
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.authorizeWorker(m);
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.revokeWorker();
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.callFor(address(token), "");
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.withdrawETH(0);
        vm.expectRevert(CollateralVault.Unauthorized.selector);
        vault.withdrawToken(address(token), 0);
        vm.stopPrank();

        vm.startPrank(alice);
        CollateralVault.WorkerAuthorization memory bad = _auth(vault);
        bad.expiresAt = uint64(vm.getBlockTimestamp());
        vm.expectRevert(CollateralVault.InvalidAuthorization.selector);
        vault.authorizeWorker(bad);
        bad = _auth(vault);
        bad.deviceKey = bytes32(0);
        vm.expectRevert(CollateralVault.InvalidAuthorization.selector);
        vault.authorizeWorker(bad);
        bad = _auth(vault);
        bad.nonce = bytes32(0);
        vm.expectRevert(CollateralVault.InvalidAuthorization.selector);
        vault.authorizeWorker(bad);
        bad = _auth(vault);
        bad.relayOrigin = "";
        vm.expectRevert(CollateralVault.InvalidAuthorization.selector);
        vault.authorizeWorker(bad);
        bad = _auth(vault);
        bad.relayOrigin = string(new bytes(257));
        vm.expectRevert(CollateralVault.InvalidAuthorization.selector);
        vault.authorizeWorker(bad);
        bad = _auth(vault);
        bad.relayOrigin = string(new bytes(256));
        vault.authorizeWorker(bad); // the maximum length is inclusive
        assertEq(vault.isValidSignature(vault.workerDigest(), ""), bytes4(0x1626ba7e));
        vault.authorizeWorker(m); // re-authorizing replaces the digest
        assertEq(vault.isValidSignature(vault.workerAuthorizationDigest(bad), ""), bytes4(0xffffffff));
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vault.isValidSignature(vault.workerDigest(), ""), bytes4(0x1626ba7e), "expiry is inclusive");
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vault.isValidSignature(vault.workerDigest(), ""), bytes4(0xffffffff));

        address eoa = makeAddr("eoa");
        address factory = address(shop.vaultFactory());
        vm.expectRevert(CollateralVault.ForbiddenTarget.selector);
        vault.callFor(eoa, "");
        vm.expectRevert(CollateralVault.ForbiddenTarget.selector);
        vault.callFor(address(vault), "");
        // A reverting target (the factory refuses callers other than the shop) surfaces as CallFailed.
        vm.expectRevert(CollateralVault.CallFailed.selector);
        vault.callFor(factory, abi.encodeCall(VaultFactory.create, ()));
        vm.expectRevert(PullPayments.NothingToClaim.selector);
        vault.withdrawETH(1);
        vm.expectRevert(CollateralVault.ForbiddenTarget.selector);
        vault.withdrawToken(address(nft), 1);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(vault));
    }

    // ---------------------------------------------------------------- LockDiscount

    function test_lockDiscountInputGuardsAndTierThresholds() public {
        vm.expectRevert(LockDiscount.Unauthorized.selector);
        new LockDiscount(address(0), address(shop));
        vm.expectRevert(LockDiscount.Unauthorized.selector);
        new LockDiscount(address(token), address(0));

        vm.startPrank(alice);
        vm.expectRevert(LockDiscount.InvalidAmount.selector);
        discount.lock(0);
        vm.expectRevert(LockDiscount.InvalidAmount.selector);
        discount.unlock(0);
        vm.expectRevert(LockDiscount.Committed.selector);
        discount.unlock(1);
        vm.expectRevert(LockDiscount.Unauthorized.selector);
        discount.commit(1, alice, 1 ether);
        vm.expectRevert(LockDiscount.Unauthorized.selector);
        discount.release(1);
        vm.stopPrank();

        vm.startPrank(address(shop));
        vm.expectRevert(LockDiscount.InvalidLoan.selector);
        discount.commit(5, address(0), 1 ether);
        assertEq(discount.commit(5, alice, 1 ether), 1 ether);
        vm.expectRevert(LockDiscount.InvalidLoan.selector);
        discount.commit(5, bob, 1 ether); // a loan's commitment can never change borrower
        vm.expectRevert(LockDiscount.InvalidLoan.selector);
        discount.release(6);
        discount.release(5);
        vm.expectRevert(LockDiscount.InvalidLoan.selector);
        discount.release(5);
        vm.stopPrank();

        assertEq(discount.tierAmount(0), 0);
        assertEq(discount.tierAmount(4), 0);
        assertEq(discount.tierAmount(255), 0);
        _lock(1_000_000 ether - 1);
        assertEq(discount.tierOf(alice), 0);
        _lock(1);
        assertEq(discount.tierOf(alice), 1);
        _lock(4_000_000 ether - 1);
        assertEq(discount.tierOf(alice), 1);
        _lock(1);
        assertEq(discount.tierOf(alice), 2);
        _lock(15_000_000 ether - 1);
        assertEq(discount.tierOf(alice), 2);
        _lock(1);
        assertEq(discount.tierOf(alice), 3);
        assertEq(discount.unlockable(alice), 20_000_000 ether);
        assertEq(discount.locked(alice), token.balanceOf(address(discount)));
    }

    // ---------------------------------------------------------------- MilestoneBurn

    function test_burnVaultConstructorSetupAndBurnGuards() public {
        address signer = vm.addr(KEY);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        new MilestoneBurn(address(0), owner, signer, address(shop));
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        new MilestoneBurn(address(token), address(0), signer, address(shop));
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        new MilestoneBurn(address(token), owner, signer, address(0));
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new MilestoneBurn(address(token), owner, address(0), address(shop));

        MilestoneBurn burnVault = new MilestoneBurn(address(token), owner, signer, address(shop));
        bytes32 question = keccak256("test-only market cap question");
        vm.prank(alice);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(question);
        vm.startPrank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(bytes32(0));
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(question); // nothing to replace yet
        vm.stopPrank();

        OracleAttestation.Attestation memory a = _attestation(question, burnVault.MILESTONE());
        bytes memory sig = _signature(burnVault, a);
        vm.expectRevert(MilestoneBurn.NotConfigured.selector);
        burnVault.burn(a, sig);
        vm.prank(owner);
        burnVault.setQuestionHashOnce(question);
        vm.expectRevert(MilestoneBurn.EmptyVault.selector);
        burnVault.burn(a, sig);
        assertFalse(burnVault.consumed(a.requestId));

        token.transfer(address(burnVault), 1_000 ether);
        OracleAttestation.Attestation memory low = _attestation(question, burnVault.MILESTONE() - 1);
        bytes memory lowSig = _signature(burnVault, low);
        vm.expectRevert(MilestoneBurn.MilestoneNotReached.selector);
        burnVault.burn(low, lowSig);
        OracleAttestation.Attestation memory wrongType = _attestation(question, burnVault.MILESTONE());
        wrongType.answerType = 2;
        bytes memory wrongTypeSig = _signature(burnVault, wrongType);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, 3, 2));
        burnVault.burn(wrongType, wrongTypeSig);
        assertEq(token.balanceOf(address(burnVault)), 1_000 ether);

        // Exactly the milestone burns everything the vault holds, once.
        burnVault.burn(a, sig);
        assertTrue(burnVault.burned());
        assertEq(burnVault.burnedAmount(), 1_000 ether);
        assertEq(token.balanceOf(burnVault.BURN_DESTINATION()), 1_000 ether);
        assertEq(token.balanceOf(address(burnVault)), 0);
        assertEq(token.totalSupply(), 1e27, "a sink transfer is not a supply burn");
        vm.expectRevert(MilestoneBurn.AlreadyBurned.selector);
        burnVault.burn(a, sig);
        vm.startPrank(owner);
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.replaceQuestionHash(keccak256("later"));
        vm.expectRevert(MilestoneBurn.Unauthorized.selector);
        burnVault.setQuestionHashOnce(keccak256("later"));
        vm.stopPrank();
        // Tokens sent after the burn are stranded by design: no second burn, no withdrawal.
        token.transfer(address(burnVault), 1 ether);
        OracleAttestation.Attestation memory again = _attestation(question, burnVault.MILESTONE());
        bytes memory againSig = _signature(burnVault, again);
        vm.expectRevert(MilestoneBurn.AlreadyBurned.selector);
        burnVault.burn(again, againSig);
        assertEq(token.balanceOf(address(burnVault)), 1 ether);
    }

    receive() external payable {}
}
