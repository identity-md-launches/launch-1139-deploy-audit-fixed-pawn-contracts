// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {Test} from "forge-std/Test.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LockDiscount} from "../src/LockDiscount.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockNFT, MockWETH} from "./helpers/Mocks.sol";

contract PawnHandler is Test {
    PawnShop public shop;
    LendingPool public pool;
    LockDiscount public discount;
    LaunchToken public token;
    MockNFT public nft;
    uint256 public nonce;
    uint256 public nextNFT = 1;
    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostDonations;
    uint256 public ghostSettlements;
    uint256 public ghostBorrowed;
    uint256 public ghostReserves;
    bytes32 private constant QUESTION = 0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1;

    constructor(PawnShop shop_, LaunchToken token_, MockNFT nft_) {
        shop = shop_;
        pool = shop_.lendingPool();
        discount = LockDiscount(shop_.discountModule());
        token = token_;
        nft = nft_;
        nft.setApprovalForAll(address(shop), true);
        token.approve(address(discount), 100_000_000 ether);
    }

    function deposit(uint256 seed) external {
        uint256 room = pool.maxDeposit(address(this));
        if (room == 0) return;
        uint256 amount = bound(seed, 1, room);
        if (pool.previewDeposit(amount) == 0) return;
        pool.depositETH{value: amount}(address(this));
        ghostDeposits += amount;
    }

    function withdraw(uint256 seed) external {
        uint256 available = pool.maxWithdraw(address(this));
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        pool.withdrawETH(amount, address(this), address(this));
        ghostWithdrawals += amount;
    }

    function donate(uint256 seed) external {
        uint256 amount = bound(seed, 1, 0.1 ether);
        pool.donate{value: amount}();
        ghostDonations += amount;
    }

    function advanceAndPublish(uint256 secondsSeed, uint256 priceSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 40 days));
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invariant oracle", ++nonce));
        a.chainId = 1;
        a.questionHash = QUESTION;
        a.answerType = 3;
        a.answer = abi.encode(bound(priceSeed, 0.025 ether, 5 ether));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 26 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xA11CE, shop.attestationDigest(a));
        shop.submitFloor(address(nft), a, abi.encodePacked(r, s, v));
    }

    function pawn(uint256 termSeed) external {
        if (shop.nextLoanId() > 24 || !shop.floorFresh(address(nft))) return;
        (uint256 floor,,,) = shop.floors(address(nft));
        uint256 principal = floor * 4000 / 10000;
        if (principal > pool.idleAssets() || shop.collectionDebt(address(nft)) + principal > pool.totalAssets()) {
            return;
        }
        uint256 tokenId = nextNFT++;
        nft.mint(address(this), tokenId);
        uint256 reserveBefore = pool.shortfallReserve();
        shop.pawn(address(nft), tokenId, uint8(termSeed % 2), 0, type(uint256).max);
        ghostReserves += pool.shortfallReserve() - reserveBefore;
        ghostBorrowed += principal;
    }

    function repayOrAuction(uint256 idSeed, bool auction, uint256 elapsedSeed) external {
        uint256 count = shop.nextLoanId() - 1;
        if (count == 0) return;
        uint256 id = 1 + idSeed % count;
        PawnShop.Loan memory loan = shop.getLoan(id);
        if (loan.status == PawnShop.Status.Active) {
            if (!auction) {
                shop.repay{value: loan.principal}(id);
                ghostSettlements += loan.principal;
                return;
            }
            if (vm.getBlockTimestamp() <= loan.due + 3 days || !shop.floorFresh(address(nft))) return;
            shop.startAuction(id);
        } else if (loan.status != PawnShop.Status.Auction) {
            return;
        }
        vm.warp(vm.getBlockTimestamp() + bound(elapsedSeed, 1, 45 days));
        if (!shop.writtenOff(id)) {
            if (vm.getBlockTimestamp() >= shop.getLoan(id).auctionStarted + 40 days && elapsedSeed % 2 == 0) {
                shop.writeOffAuction(id);
            } else {
                shop.markAuctionLoss(id);
            }
        }
        // Keep some marked/written-off auctions open across lender deposits and withdrawals.
        if (elapsedSeed % 3 == 0) return;
        uint256 price = shop.auctionPrice(id);
        shop.buyAuction{value: price}(id, address(this));
        ghostSettlements += price < loan.principal ? price : loan.principal;
    }

    function lockOrUnlock(uint256 seed, bool locking) external {
        uint256 available = locking ? token.balanceOf(address(this)) : discount.unlockable(address(this));
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        if (locking) {
            token.approve(address(discount), amount);
            discount.lock(amount);
        } else {
            discount.unlock(amount);
        }
    }

    function claim() external {
        if (shop.claimable(address(this)) != 0) shop.claim(payable(address(this)));
        if (pool.claimable(address(this)) != 0) pool.claim(payable(address(this)));
    }

    receive() external payable {}
}

contract PawnInvariantTest is PawnTestBase {
    PawnHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new PawnHandler(shop, token, nft);
        vm.deal(address(handler), 100_000 ether);
        token.transfer(address(handler), 100_000_000 ether);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.advanceAndPublish.selector;
        selectors[4] = handler.pawn.selector;
        selectors[5] = handler.repayOrAuction.selector;
        selectors[6] = handler.lockOrUnlock.selector;
        selectors[7] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_poolBookMatchesCashAndDebt() public view {
        uint256 cash = weth.balanceOf(address(pool));
        uint256 recognised = cash + pool.totalBorrowed()
            - (pool.shortfallReserve() > pool.expectedAuctionLoss()
                    ? pool.shortfallReserve()
                    : pool.expectedAuctionLoss()) - pool.unvestedDonations();
        uint256 release = pool.unvestedRelease();
        // The unvested release defers recognition but never pushes the book below zero (launch review e5e83677).
        assertEq(pool.totalAssets(), recognised - (release > recognised ? recognised : release));
        assertEq(pool.idleAssets() + pool.shortfallReserve() + pool.unvestedDonations(), cash);
        assertEq(
            cash,
            (5 ether
                    + handler.ghostDeposits()
                    + handler.ghostDonations()
                    + handler.ghostSettlements()
                    + pool.cumulativeLoanFees()
                    + handler.ghostReserves()) - (handler.ghostBorrowed() + handler.ghostWithdrawals())
        );
        assertEq(
            recognised,
            5 ether + handler.ghostDeposits() + handler.ghostDonations() + pool.cumulativeLoanFees()
                - handler.ghostWithdrawals() - pool.unvestedDonations() - pool.cumulativeLoss()
                + pool.cumulativeRecoveries()
                - (pool.expectedAuctionLoss() > pool.shortfallReserve()
                        ? pool.expectedAuctionLoss() - pool.shortfallReserve()
                        : 0)
        );
    }

    function invariant_debtAndCollateralFollowLoanState() public view {
        uint256 sum;
        uint256 borrowed;
        uint256 maximumCommitment;
        for (uint256 id = 1; id < shop.nextLoanId(); ++id) {
            PawnShop.Loan memory loan = shop.getLoan(id);
            (address borrower, uint8 tier) = discount.commitments(id);
            if (loan.status == PawnShop.Status.Active || loan.status == PawnShop.Status.Auction) {
                assertEq(nft.ownerOf(loan.tokenId), loan.vault);
                // A held written-off loan leaves the collection's share but stays on the pool's book.
                if (!shop.debtRealised(id)) borrowed += loan.principal;
                if (shop.writtenOff(id)) {
                    assertEq(borrower, address(0));
                } else {
                    sum += loan.principal;
                    assertEq(borrower, loan.borrower);
                    uint256 amount = discount.tierAmount(tier);
                    if (amount > maximumCommitment) maximumCommitment = amount;
                }
            } else {
                assertEq(nft.ownerOf(loan.tokenId), address(handler));
                assertEq(borrower, address(0));
            }
        }
        assertEq(borrowed, pool.totalBorrowed());
        assertEq(sum, shop.collectionDebt(address(nft)));
        assertEq(discount.committed(address(handler)), maximumCommitment);
        assertGe(discount.locked(address(handler)), maximumCommitment);
        assertEq(token.balanceOf(address(discount)), discount.locked(address(handler)));
    }

    function invariant_ETHCreditsAreFullyBacked() public view {
        assertEq(address(shop).balance, shop.totalClaimable() + shop.bountyReserve());
        assertEq(address(pool).balance, pool.totalClaimable());
        assertEq(token.totalSupply(), 1e27);
    }
}
